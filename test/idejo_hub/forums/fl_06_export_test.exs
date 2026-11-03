# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL06ExportTest do
  @moduledoc "FL-06: exporting a forum as a standard Idejo backup, kept by the Hub."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias DockerGuard.Policy
  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, Export, ExportWorker, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{ForumContainer, Postgres}

  @moduletag req: "FL-06"
  @moduletag :capture_log

  @backup ["/app/bin/idejo-admin", "backup"]
  @file_path "/data/backups/idejo-20261103-120000.tar"

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())
    on_exit(fn -> Postgres.drop("fl06-tennis") end)

    {:ok, forum} =
      Forums.create_forum(
        %{
          "subdomain" => "fl06-tennis",
          "display_name" => "Tennis",
          "owner_email" => "o@example.test"
        },
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    %{forum: Forums.get_forum!(forum.id)}
  end

  defp backup_ok do
    Fake.run_result(
      @backup,
      0,
      "Backup written to #{@file_path}\nOld backup idejo-1.tar deleted\n"
    )

    Fake.put_file(@file_path, "tar bytes")
  end

  defp export(forum) do
    {:ok, forum} = Forums.export_forum(forum, "operator")
    assert forum.step == "exporting"
    perform_job(ExportWorker, %{"forum_id" => forum.id, "actor" => "operator"})
  end

  test "runs idejo-admin backup in a one-off container and keeps the file", %{forum: forum} do
    backup_ok()
    assert :ok = export(forum)

    [export] = Forums.list_exports(forum)
    assert export.kind == "export"
    assert export.file_name == "idejo-20261103-120000.tar"
    assert File.read!(Export.path(export)) == "tar bytes"
    assert export.size == 9
    assert export.sha256 == Base.encode16(:crypto.hash(:sha256, "tar bytes"), case: :lower)

    state = Fake.state()
    one_off = "idejo-forum-fl06-tennis-export"
    # Made from the forum's own spec, with the backup command, then removed.
    refute Map.has_key?(state.containers, one_off)
    assert Forums.get_forum!(forum.id).step == nil

    entry =
      Audit.for_forum(forum.id)
      |> Enum.find(&(&1.action == "forum.export" and &1.outcome == "ok"))

    assert entry.details["sha256"] == export.sha256
  end

  test "the one-off container has the forum's environment and volumes, and never restarts", %{
    forum: forum
  } do
    {:ok, params} = Forums.container_params(forum)
    spec = ForumContainer.one_off_spec(params, @backup)

    assert spec["Cmd"] == @backup
    assert spec["HostConfig"]["RestartPolicy"] == %{"Name" => "no"}

    assert spec["HostConfig"]["Mounts"] ==
             ForumContainer.spec(params)["HostConfig"]["Mounts"]

    assert Enum.any?(spec["Env"], &String.starts_with?(&1, "DATABASE_URL="))

    # And docker-guard allows it.
    body = spec |> Jason.encode!() |> Jason.decode!()
    lookup = %{container_labels: fn _ -> :error end, exec_container: fn _ -> :error end}

    assert Policy.check(
             %{
               method: "POST",
               path: ["containers", "create"],
               query: %{"name" => "idejo-forum-fl06-tennis-export"},
               body: body
             },
             %{image: "ghcr.io/callisto-rpg/idejo", network: "idejo-forums"},
             lookup
           ) == :ok
  end

  test "a suspended forum can be exported too", %{forum: forum} do
    {:ok, forum} = Forums.suspend_forum(forum, "operator")
    :ok = perform_job(SuspendWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    backup_ok()

    assert :ok = export(Forums.get_forum!(forum.id))
    assert Forums.get_forum!(forum.id).status == "suspended"
    assert [_] = Forums.list_exports(forum)
  end

  test "a failed backup keeps nothing and removes the one-off container", %{forum: forum} do
    Fake.run_result(@backup, 1, "Backup failed: pg_dump")
    assert {:error, "idejo-admin backup exited with 1"} = export(forum)

    assert Forums.list_exports(forum) == []
    refute Map.has_key?(Fake.state().containers, "idejo-forum-fl06-tennis-export")
    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    assert forum.error == "idejo-admin backup exited with 1"
  end

  test "only a file in the forum's backups directory is copied", %{forum: forum} do
    Fake.run_result(@backup, 0, "Backup written to /etc/passwd\n")
    assert {:error, "idejo-admin backup did not name its file"} = export(forum)
    assert Forums.list_exports(forum) == []
  end

  test "only running or suspended forums, one action at a time", %{forum: forum} do
    {:ok, busy} = Forums.export_forum(forum, "operator")
    assert Forums.export_forum(busy, "operator") == {:error, :invalid_state}
  end
end
