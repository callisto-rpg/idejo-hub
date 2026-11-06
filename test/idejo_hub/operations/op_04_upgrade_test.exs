# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP04UpgradeTest do
  @moduledoc """
  OP-04: upgrade one forum: backup, pull, restart, wait for a healthy health check, and roll
  back to the previous image and backup on failure.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, Export}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}
  alias IdejoHub.Operations.UpgradeWorker

  @moduletag req: "OP-04"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @container "idejo-forum-op04-a"
  @file_path "/data/backups/idejo-20261103-150000.tar"

  setup do
    Fake.start()
    healthy_unless(nil)
    File.rm_rf!(Export.dir())
    on_exit(fn -> Postgres.drop("op04-a") end)

    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "op04-a", "display_name" => "A", "owner_email" => "o@example.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    # Maintenance marks are files that outlive a test: start from an unmarked host (a test
    # that leaves its forum suspended leaves the mark).
    Maintenance.unmark(Forums.host(forum))

    Fake.exec_result(
      [@admin, "backup"],
      {:ok, %{exit_code: 0, output: "Backup written to #{@file_path}\n"}}
    )

    Fake.put_file(@file_path, "pre-upgrade")
    %{forum: Forums.get_forum!(forum.id)}
  end

  # /health fails while the forum's container runs `bad_version`.
  defp healthy_unless(bad_version) do
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn ->
      image = get_in(Fake.state().containers, [@container, "Spec", "Image"])

      status =
        if bad_version && image == "ghcr.io/callisto-rpg/idejo:#{bad_version}", do: 503, else: 200

      send_resp(conn, status, "{}")
    end)
  end

  defp upgrade(forum, version) do
    {:ok, forum} = Forums.upgrade_forum(forum, version, "operator")
    assert forum.step == "upgrading"

    perform_job(UpgradeWorker, %{
      "forum_id" => forum.id,
      "version" => version,
      "actor" => "operator"
    })
  end

  defp container, do: Fake.state().containers[@container]

  defp env(name),
    do: Enum.find_value(container()["Spec"]["Env"], &(String.starts_with?(&1, name <> "=") && &1))

  test "backs up, pulls, recreates on the new image with its source link, and waits for health",
       %{forum: forum} do
    assert :ok = upgrade(forum, "0.2.0")

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    assert forum.idejo_version == "0.2.0"
    assert container()["Spec"]["Image"] == "ghcr.io/callisto-rpg/idejo:0.2.0"
    assert container()["Running"]
    # LB-03: the source link follows the version.
    assert env("IDEJO_SOURCE_URL") ==
             "IDEJO_SOURCE_URL=https://github.com/callisto-rpg/Idejo/tree/v0.2.0"

    # Volumes untouched.
    assert map_size(Fake.state().volumes) == 2
    refute Maintenance.marked?(Forums.host(forum))

    assert [%{kind: "upgrade"}] = Forums.list_exports(forum)

    entry =
      Enum.find(Audit.for_forum(forum.id), &(&1.action == "forum.upgrade" and &1.outcome == "ok"))

    assert entry.details["from"] == "0.1.0" and entry.details["to"] == "0.2.0"
  end

  test "an unhealthy new version is rolled back to the old image and the backup", %{forum: forum} do
    healthy_unless("0.2.0")
    assert {:error, "no healthy answer in time"} = upgrade(forum, "0.2.0")

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    assert forum.idejo_version == "0.1.0"
    assert container()["Spec"]["Image"] == "ghcr.io/callisto-rpg/idejo:0.1.0"
    assert container()["Running"]
    assert env("IDEJO_SOURCE_URL") =~ "tree/v0.1.0"
    refute Maintenance.marked?(Forums.host(forum))

    # The pre-upgrade backup was restored with the old image, in a one-off container.
    assert {"idejo-forum-op04-a-restore",
            [@admin, "restore", "idejo-20261103-150000.tar", "--yes"]} in Fake.state().runs_seen

    assert get_in(Fake.state().containers, ["idejo-forum-op04-a-restore"]) == nil

    entry =
      Enum.find(
        Audit.for_forum(forum.id),
        &(&1.action == "forum.upgrade" and &1.outcome == "failed")
      )

    assert entry.details["rolled_back"] == true
  end

  test "a failed rollback leaves the forum stopped behind the maintenance page", %{forum: forum} do
    healthy_unless("0.2.0")
    Fake.run_result([@admin, "restore"], 1, "Restore failed")
    assert {:error, _} = upgrade(forum, "0.2.0")

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "suspended"
    assert Maintenance.marked?(Forums.host(forum))
    refute container()["Running"]

    entry =
      Enum.find(
        Audit.for_forum(forum.id),
        &(&1.action == "forum.upgrade" and &1.outcome == "failed")
      )

    assert entry.details["rolled_back"] == false
    assert entry.details["rollback_error"] == "idejo-admin restore exited with 1"
  end

  test "a version that cannot be pulled changes nothing", %{forum: forum} do
    Fake.fail(:pull_image, :not_found)

    assert {:error, "image ghcr.io/callisto-rpg/idejo:9.9.9 could not be pulled"} =
             upgrade(forum, "9.9.9")

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    assert forum.idejo_version == "0.1.0"
    assert container()["Spec"]["Image"] == "ghcr.io/callisto-rpg/idejo:0.1.0"
    assert container()["Running"]
    refute Maintenance.marked?(Forums.host(forum))
  end

  test "only newer exact versions, running forums, one action at a time", %{forum: forum} do
    assert Forums.upgrade_forum(forum, "0.1.0", "operator") == {:error, :not_newer}
    assert Forums.upgrade_forum(forum, "0.0.9", "operator") == {:error, :not_newer}
    assert Forums.upgrade_forum(forum, "latest", "operator") == {:error, :invalid_version}
    {:ok, busy} = Forums.upgrade_forum(forum, "0.2.0", "operator")
    assert Forums.upgrade_forum(busy, "0.3.0", "operator") == {:error, :invalid_state}
  end
end
