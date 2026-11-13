# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP01BackupTest do
  @moduledoc "OP-01: scheduled backups per forum (daily, 14 kept), through idejo's CLI backup."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{Archives, CreateWorker, Export, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.{BackupScheduler, BackupWorker}

  @moduletag req: "OP-01"
  @moduletag :capture_log

  @backup ["/app/bin/idejo-admin", "backup"]

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())
    on_exit(fn -> for s <- ["op01-a", "op01-b"], do: Postgres.drop(s) end)
    %{forum: create("op01-a")}
  end

  defp create(subdomain) do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => "F", "owner_email" => "o@example.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  # Each backup writes a new file, as idejo does.
  defp backup_writes(n) do
    path = "/data/backups/idejo-20261103-#{String.pad_leading("#{n}", 6, "0")}.tar"
    Fake.exec_result(@backup, {:ok, %{exit_code: 0, output: "Backup written to #{path}\n"}})
    Fake.put_file(path, "backup #{n}")
  end

  defp back_up(forum) do
    {:ok, forum} = Forums.backup_forum(forum, "schedule")
    perform_job(BackupWorker, %{"forum_id" => forum.id, "actor" => "schedule"})
  end

  test "runs idejo-admin backup inside the running container and keeps the file", %{forum: forum} do
    backup_writes(1)
    assert :ok = back_up(forum)

    assert {"idejo-forum-op01-a", @backup} in Fake.state().execs
    [backup] = Forums.list_exports(forum)
    assert backup.kind == "backup"
    assert File.read!(Export.path(backup)) == "backup 1"
    assert Forums.get_forum!(forum.id).step == nil

    entry =
      Enum.find(Audit.for_forum(forum.id), &(&1.action == "forum.backup" and &1.outcome == "ok"))

    assert entry.actor == "schedule"
    assert entry.details["sha256"] == backup.sha256
  end

  test "keeps the newest 14 backups of each forum, never exports", %{forum: forum} do
    Fake.run_result(@backup, 0, "Backup written to /data/backups/idejo-20261101-000000.tar\n")
    Fake.put_file("/data/backups/idejo-20261101-000000.tar", "export")

    :ok =
      perform_job(IdejoHub.Forums.ExportWorker, %{
        "forum_id" => elem(Forums.export_forum(forum, "op"), 1).id,
        "actor" => "op"
      })

    for n <- 1..16 do
      backup_writes(n)
      assert :ok = back_up(Forums.get_forum!(forum.id))
    end

    backups = for e <- Forums.list_exports(forum), e.kind == "backup", do: e.file_name
    assert length(backups) == 14
    assert hd(backups) == "idejo-20261103-000016.tar"
    refute "idejo-20261103-000002.tar" in backups
    refute File.exists?(Path.join([Export.dir(), "op01-a", "idejo-20261103-000001.tar"]))

    assert [%{kind: "export"}] = for(e <- Forums.list_exports(forum), e.kind == "export", do: e)
  end

  test "a failed backup keeps nothing, records why, and frees the forum", %{forum: forum} do
    Fake.exec_result(@backup, {:ok, %{exit_code: 1, output: "Backup failed: pg_dump"}})
    assert {:error, "idejo-admin backup exited with 1"} = back_up(forum)

    assert Forums.list_exports(forum) == []
    forum = Forums.get_forum!(forum.id)
    assert forum.step == nil
    assert forum.status == "running"

    assert Enum.any?(
             Audit.for_forum(forum.id),
             &(&1.action == "forum.backup" and &1.outcome == "failed")
           )
  end

  test "the schedule backs up running forums only, and skips busy ones", %{forum: forum} do
    other = create("op01-b")
    {:ok, _} = Forums.suspend_forum(other, "op")
    :ok = perform_job(SuspendWorker, %{"forum_id" => other.id, "actor" => "op"})

    assert :ok = perform_job(BackupScheduler, %{})
    assert_enqueued(worker: BackupWorker, args: %{"forum_id" => forum.id, "actor" => "schedule"})
    refute_enqueued(worker: BackupWorker, args: %{"forum_id" => other.id})

    # The first forum now has a backup under way: the next run skips it.
    assert :ok = perform_job(BackupScheduler, %{})
    assert length(all_enqueued(worker: BackupWorker)) == 1
  end

  test "prune deletes only the given kind beyond the newest ones", %{forum: forum} do
    assert Archives.prune(forum, "backup", 14) == []
  end

  test "the schedule is daily by default" do
    {Oban.Plugins.Cron, opts} =
      Enum.find(
        Application.fetch_env!(:idejo_hub, Oban)[:plugins],
        &match?({Oban.Plugins.Cron, _}, &1)
      )

    assert {"0 2 * * *", BackupScheduler} in opts[:crontab]
    assert Application.fetch_env!(:idejo_hub, IdejoHub.Operations)[:backups_kept] == 14
  end
end
