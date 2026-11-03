# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP03RestoreTest do
  @moduledoc "OP-03: restore a forum from any kept backup, to the same subdomain or a new one."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.{CreateWorker, DeleteWorker, Export, PurgeWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}
  alias IdejoHub.Operations.{BackupWorker, RestoreWorker}

  @moduletag req: "OP-03"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @file_path "/data/backups/idejo-20261103-140000.tar"

  setup do
    Fake.start()
    healthy(200)
    File.rm_rf!(Export.dir())
    on_exit(fn -> for s <- ["op03-a", "op03-b"], do: Postgres.drop(s) end)

    forum = create("op03-a")

    Fake.exec_result(
      [@admin, "backup"],
      {:ok, %{exit_code: 0, output: "Backup written to #{@file_path}\n"}}
    )

    Fake.put_file(@file_path, "kept backup")
    {:ok, _} = Forums.backup_forum(forum, "schedule")
    :ok = job(BackupWorker, forum)
    [backup] = Forums.list_exports(forum)
    %{forum: Forums.get_forum!(forum.id), backup: backup}
  end

  defp healthy(status),
    do: Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, status, "{}") end)

  defp create(subdomain) do
    {:ok, forum} =
      Forums.create_forum(
        %{
          "subdomain" => subdomain,
          "display_name" => "Club A",
          "owner_email" => "o@example.test"
        },
        "operator"
      )

    :ok = job(CreateWorker, forum)
    Forums.get_forum!(forum.id)
  end

  defp job(worker, forum, extra \\ %{}) do
    perform_job(worker, Map.merge(%{"forum_id" => forum.id, "actor" => "operator"}, extra))
  end

  defp run_restore(forum) do
    [job] = all_enqueued(worker: RestoreWorker, args: %{"forum_id" => forum.id})
    perform_job(RestoreWorker, job.args)
  end

  defp one_off_cmds, do: for({name, c} <- Fake.state().runs_seen, do: {name, c})

  describe "to the same subdomain" do
    test "stops the forum, restores the file in a one-off container, starts it again",
         %{forum: forum, backup: backup} do
      assert {:ok, %{step: "restoring"}} = Forums.restore_forum(forum, backup, "operator")
      assert :ok = run_restore(forum)

      state = Fake.state()

      assert {"idejo-forum-op03-a", "/data/backups/#{backup.file_name}", "kept backup"} in state.copied

      assert one_off_cmds() == [
               {"idejo-forum-op03-a-restore", [@admin, "restore", backup.file_name, "--yes"]}
             ]

      refute Map.has_key?(state.containers, "idejo-forum-op03-a-restore")
      assert state.containers["idejo-forum-op03-a"]["Running"]

      forum = Forums.get_forum!(forum.id)
      assert forum.status == "running"
      refute Maintenance.marked?(Forums.host(forum))

      assert Enum.any?(
               Audit.for_forum(forum.id),
               &(&1.action == "forum.restore" and &1.outcome == "ok")
             )
    end

    test "a failed restore keeps the forum stopped behind the maintenance page",
         %{forum: forum, backup: backup} do
      Fake.run_result([@admin, "restore"], 1, "Restore failed")
      {:ok, _} = Forums.restore_forum(forum, backup, "operator")
      assert {:error, "idejo-admin restore exited with 1"} = run_restore(forum)

      forum = Forums.get_forum!(forum.id)
      assert forum.status == "suspended"
      assert Maintenance.marked?(Forums.host(forum))
      refute Fake.state().containers["idejo-forum-op03-a"]["Running"]
    end

    test "a restored forum that is not healthy stays behind the page", %{
      forum: forum,
      backup: backup
    } do
      healthy(503)
      {:ok, _} = Forums.restore_forum(forum, backup, "operator")
      assert {:error, _} = run_restore(forum)
      assert Forums.get_forum!(forum.id).status == "suspended"
      assert Maintenance.marked?(Forums.host(forum))
    end

    test "a failure before the restore puts the forum back as it was", %{
      forum: forum,
      backup: backup
    } do
      Fake.fail(:copy_to, {:unreachable, "closed"})
      {:ok, _} = Forums.restore_forum(forum, backup, "operator")
      assert {:error, "Docker is unreachable"} = run_restore(forum)

      forum = Forums.get_forum!(forum.id)
      assert forum.status == "running"
      refute Maintenance.marked?(Forums.host(forum))
      assert Fake.state().containers["idejo-forum-op03-a"]["Running"]
    end

    test "only the forum's own archives", %{backup: backup} do
      other = create("op03-b")
      assert Forums.restore_forum(other, backup, "operator") == {:error, :not_its_archive}
    end
  end

  describe "to a new subdomain" do
    test "from a live forum: own key, no setup, new push keys, then restored", %{
      forum: source,
      backup: backup
    } do
      assert {:ok, new} = Forums.restore_to_new(backup, %{"subdomain" => "op03-b"}, "operator")
      assert new.display_name == source.display_name
      assert new.idejo_version == source.idejo_version
      {:ok, new_key} = Forums.secret(new, :secret_key_base)
      {:ok, source_key} = Forums.secret(source, :secret_key_base)
      assert new_key != source_key

      :ok =
        perform_job(
          CreateWorker,
          (all_enqueued(worker: CreateWorker, args: %{"forum_id" => new.id}) |> hd()).args
        )

      assert Maintenance.marked?(Forums.host(new))

      refute Enum.any?(Fake.state().execs, fn {c, cmd} ->
               c == "idejo-forum-op03-b" and Enum.at(cmd, 1) == "setup"
             end)

      assert :ok = run_restore(new)
      assert {"idejo-forum-op03-b-keys", [@admin, "rotate-push-keys", "--yes"]} in one_off_cmds()
      new = Forums.get_forum!(new.id)
      assert new.status == "running"
      refute Maintenance.marked?(Forums.host(new))
      # The source is untouched.
      assert Forums.get_forum!(source.id).status == "running"
    end

    test "from a deleted forum: its key moves with its data", %{forum: source} do
      Fake.run_result([@admin, "backup"], 0, "Backup written to #{@file_path}\n")
      {:ok, _} = Forums.delete_forum(source, "operator", immediate: true, confirm: "op03-a")
      :ok = job(DeleteWorker, source, %{"immediate" => true})
      :ok = job(PurgeWorker, source)
      [final] = for e <- Forums.list_exports(source), e.kind == "final", do: e
      {:ok, source_key} = Forums.secret(Forums.get_forum!(source.id), :secret_key_base)

      {:ok, new} = Forums.restore_to_new(final, %{"subdomain" => "op03-a"}, "operator")
      assert Forums.secret(new, :secret_key_base) == {:ok, source_key}

      assert [%{"restore" => %{"rotate_push_keys" => false}}] =
               for(
                 j <- all_enqueued(worker: CreateWorker, args: %{"forum_id" => new.id}),
                 do: j.args
               )
    end
  end

  test "any kept archive kind can be restored", %{forum: forum} do
    for kind <- ~w(backup export final) do
      export =
        Repo.insert!(%Export{
          forum_id: forum.id,
          subdomain: forum.subdomain,
          kind: kind,
          file_name: "x.tar",
          size: 1,
          sha256: "0"
        })

      assert {:ok, _} = Forums.restore_forum(forum, export, "operator")
      Repo.update_all(IdejoHub.Forums.Forum, set: [step: nil])
    end
  end
end
