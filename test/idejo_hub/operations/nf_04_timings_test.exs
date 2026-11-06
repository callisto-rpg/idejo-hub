# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.NF04TimingsTest do
  @moduledoc """
  Hub NF-04: creating a forum takes under 2 minutes; upgrading one causes under 1 minute of
  downtime. Here: the new image is pulled before the maintenance page shows, so a download
  never adds to the downtime, and both durations are recorded in the audit log.
  The figures on real containers are asserted by the exit checks: deploy/test/m3/run.sh
  (creating two forums) and deploy/test/m2/run.sh (upgrading four).
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, Export}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}
  alias IdejoHub.Operations.UpgradeWorker

  @moduletag req: "NF-04"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, &send_resp(&1, 200, "{}"))
    File.rm_rf!(Export.dir())
    on_exit(fn -> Postgres.drop("nf04-a") end)

    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "nf04-a", "display_name" => "A", "owner_email" => "o@nf04.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})

    Fake.exec_result(
      [@admin, "backup"],
      {:ok,
       %{exit_code: 0, output: "Backup written to /data/backups/idejo-20261106-180000.tar\n"}}
    )

    Fake.put_file("/data/backups/idejo-20261106-180000.tar", "pre-upgrade")
    %{forum: Forums.get_forum!(forum.id)}
  end

  defp entry(action, outcome),
    do: Repo.get_by!(Audit.Entry, action: action, outcome: outcome, subdomain: "nf04-a")

  # Upgrades to 0.2.0; returns the result and the Docker calls the upgrade made, in order.
  defp upgrade(forum) do
    before = length(Fake.state().calls)
    {:ok, forum} = Forums.upgrade_forum(forum, "0.2.0", "operator")

    result =
      perform_job(UpgradeWorker, %{
        "forum_id" => forum.id,
        "version" => "0.2.0",
        "actor" => "operator"
      })

    {result, Enum.drop(Fake.state().calls, before)}
  end

  test "NF-04 creating a forum records how long it took" do
    seconds = entry("forum.create", "ok").details["seconds"]
    assert is_integer(seconds) and seconds < 120
  end

  test "NF-04 the new image is pulled while the forum still runs; the downtime is recorded", %{
    forum: forum
  } do
    {:ok, calls} = upgrade(forum)

    pull = Enum.find_index(calls, &(&1 == :pull_image))
    # The maintenance page shows just before the backup, the first exec of the upgrade.
    backup = Enum.find_index(calls, &(&1 == :exec))
    assert pull < backup

    downtime = entry("forum.upgrade", "ok").details["downtime_seconds"]
    assert is_integer(downtime) and downtime < 60
    refute Maintenance.marked?(Forums.host(forum))
  end

  test "NF-04 a failed pull causes no downtime at all", %{forum: forum} do
    Fake.fail(:pull_image)
    {{:error, _}, calls} = upgrade(forum)

    # Never marked, never backed up: the forum served throughout.
    assert calls == [:pull_image]
    refute Maintenance.marked?(Forums.host(forum))
    failed = entry("forum.upgrade", "failed")
    refute Map.has_key?(failed.details, "downtime_seconds")
    assert Forums.get_forum!(forum.id).status == "running"
  end
end
