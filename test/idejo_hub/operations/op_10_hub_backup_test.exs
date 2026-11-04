# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP10HubBackupTest do
  @moduledoc "OP-10: backup of the Hub's own database and the identity provider's, on the same schedule."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  alias IdejoHub.{Audit, Operations, Repo}
  alias IdejoHub.Audit.Entry
  alias IdejoHub.Forums.Export
  alias IdejoHub.Operations.{BackupScheduler, HubBackup, HubBackupWorker}
  alias IdejoHub.Operations.HubBackup.Backup

  @moduletag req: "OP-10"
  @moduletag :capture_log

  setup do
    File.rm_rf!(Export.dir())
    original = Application.fetch_env!(:idejo_hub, HubBackup)
    on_exit(fn -> Application.put_env(:idejo_hub, HubBackup, original) end)
    zitadel(password: "zitadel-secret")
    :ok
  end

  defp zitadel(opts) do
    config = Application.fetch_env!(:idejo_hub, HubBackup)
    zitadel = Keyword.merge(config[:zitadel], opts)
    Application.put_env(:idejo_hub, HubBackup, Keyword.put(config, :zitadel, zitadel))
  end

  defp back_up(actor \\ "operator"), do: perform_job(HubBackupWorker, %{"actor" => actor})

  defp hub_entries, do: Repo.all(from e in Entry, where: e.action == "hub.backup")

  test "dumps the Hub's database and Zitadel's, each as its own role, into the Hub's store" do
    assert :ok = back_up()

    [hub, zitadel] = Enum.sort_by(HubBackup.list(), & &1.kind)
    assert hub.kind == "hub" and zitadel.kind == "zitadel"
    assert hub.file_name =~ ~r/^hub-\d{8}-\d{6}\.dump$/
    assert Path.dirname(HubBackup.path(hub)) == Path.join(Export.dir(), "_hub")

    db = Repo.config()[:database]
    user = Repo.config()[:username]
    assert File.read!(HubBackup.path(hub)) =~ "dump of #{db} as #{user}"

    assert File.read!(HubBackup.path(zitadel)) ==
             "dump of zitadel as zitadel on db:5432 (password set)\n"

    assert hub.size == File.stat!(HubBackup.path(hub)).size

    assert hub.sha256 ==
             Base.encode16(:crypto.hash(:sha256, File.read!(HubBackup.path(hub))), case: :lower)

    assert Map.keys(HubBackup.latest()) == ["hub", "zitadel"]
  end

  test "without ZITADEL_DB_PASSWORD only the Hub's database is dumped" do
    zitadel(password: nil)
    assert :ok = back_up()
    assert [%Backup{kind: "hub"}] = HubBackup.list()
  end

  test "keeps the newest 14 of each kind and deletes older files" do
    for n <- 1..15 do
      at = DateTime.add(~U[2026-11-01 02:00:00Z], n, :hour)

      for kind <- ~w(hub zitadel) do
        name = "#{kind}-old-#{n}.dump"
        File.mkdir_p!(HubBackup.dir())
        File.write!(Path.join(HubBackup.dir(), name), "x")
        Repo.insert!(%Backup{kind: kind, file_name: name, size: 1, sha256: "x", inserted_at: at})
      end
    end

    assert :ok = back_up()

    for kind <- ~w(hub zitadel) do
      kept = Enum.filter(HubBackup.list(), &(&1.kind == kind))
      assert length(kept) == 14
      refute Enum.any?(kept, &(&1.file_name in ["#{kind}-old-1.dump", "#{kind}-old-2.dump"]))
      refute File.exists?(Path.join(HubBackup.dir(), "#{kind}-old-1.dump"))
    end

    [entry] = hub_entries()
    assert entry.outcome == "ok"

    assert Enum.sort(entry.details["pruned"]) ==
             ~w(hub-old-1.dump hub-old-2.dump zitadel-old-1.dump zitadel-old-2.dump)
  end

  test "a failed dump leaves no file, is audited without secrets, and keeps the earlier ones" do
    zitadel(database: "zitadel_fails")
    assert {:error, {:pg_dump_exit, 1}} = back_up("schedule")

    assert [%Backup{kind: "hub"}] = HubBackup.list()
    assert File.ls!(HubBackup.dir()) |> Enum.all?(&String.starts_with?(&1, "hub-"))

    [entry] = hub_entries()
    assert entry.outcome == "failed" and entry.actor == "schedule" and entry.forum_id == nil
    assert entry.details["failed"] == "zitadel"
    assert entry.details["error"] == "pg_dump exited with 1"
    refute inspect(entry.details) =~ "zitadel-secret"
  end

  test "runs on the forums' schedule, one at a time" do
    assert :ok = perform_job(BackupScheduler, %{})
    assert_enqueued(worker: HubBackupWorker, args: %{"actor" => "schedule"})

    assert {:error, :already_running} = Operations.backup_hub("operator")
    assert :ok = perform_job(BackupScheduler, %{})
    assert length(all_enqueued(worker: HubBackupWorker)) == 1
  end

  test "Operations.backup_hub/1 queues a backup for an operator" do
    assert {:ok, _job} = Operations.backup_hub("op@example.test")
    assert_enqueued(worker: HubBackupWorker, args: %{"actor" => "op@example.test"})
    assert Audit.for_forum(0) == []
  end
end
