# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL05DeleteTest do
  @moduledoc """
  FL-05: deletion in two steps, a final export first, then the purge after a 30-day grace
  period unless the operator confirms immediate deletion.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, DeleteWorker, Export, PurgeWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}

  @moduletag req: "FL-05"
  @moduletag :capture_log

  @host "fl05-tennis.idejo.test"
  @backup ["/app/bin/idejo-admin", "backup"]
  @file_path "/data/backups/idejo-20261103-130000.tar"

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())
    on_exit(fn -> Postgres.drop("fl05-tennis") end)

    {:ok, forum} = Forums.create_forum(attrs(), "operator")
    :ok = run(CreateWorker, forum)
    Fake.run_result(@backup, 0, "Backup written to #{@file_path}\n")
    Fake.put_file(@file_path, "final bytes")
    %{forum: Forums.get_forum!(forum.id)}
  end

  defp attrs,
    do: %{
      "subdomain" => "fl05-tennis",
      "display_name" => "Tennis",
      "owner_email" => "o@example.test"
    }

  defp run(worker, forum, extra \\ %{}),
    do: perform_job(worker, Map.merge(%{"forum_id" => forum.id, "actor" => "operator"}, extra))

  defp container, do: Fake.state().containers["idejo-forum-fl05-tennis"]

  test "makes a final export, stops the forum and schedules the purge 30 days on", %{forum: forum} do
    assert {:ok, %{step: "deleting"}} = Forums.delete_forum(forum, "operator")
    assert :ok = run(DeleteWorker, forum, %{"immediate" => false})

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "deleting"
    assert_in_delta DateTime.diff(forum.purge_at, DateTime.utc_now(), :day), 30, 1
    assert Maintenance.marked?(@host)
    refute container()["Running"]

    assert [%{kind: "final", file_name: "idejo-20261103-130000.tar"}] = Forums.list_exports(forum)

    assert_enqueued(
      worker: PurgeWorker,
      args: %{"forum_id" => forum.id},
      scheduled_at: {forum.purge_at, delta: 5}
    )

    # Nothing removed yet.
    assert Postgres.exists?("fl05-tennis")
    assert map_size(Fake.state().volumes) == 2
  end

  test "the purge, at its time, removes everything but the exports", %{forum: forum} do
    {:ok, _} = Forums.delete_forum(forum, "operator", immediate: true, confirm: "fl05-tennis")
    :ok = run(DeleteWorker, forum, %{"immediate" => true})
    forum = Forums.get_forum!(forum.id)
    assert DateTime.compare(forum.purge_at, DateTime.utc_now()) != :gt

    assert :ok = run(PurgeWorker, forum)

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "deleted"
    assert forum.db_password_enc == nil
    refute Postgres.exists?("fl05-tennis")
    assert Fake.state().containers == %{}
    assert Fake.state().volumes == %{}
    refute Maintenance.marked?(@host)

    [export] = Forums.list_exports(forum)
    assert File.read!(Export.path(export)) == "final bytes"

    actions = for e <- Audit.for_forum(forum.id), do: {e.action, e.outcome}
    assert {"forum.delete", "ok"} in actions
    assert {"forum.purge", "ok"} in actions
  end

  test "a purge run early waits", %{forum: forum} do
    {:ok, _} = Forums.delete_forum(forum, "operator")
    :ok = run(DeleteWorker, forum, %{"immediate" => false})
    assert {:snooze, seconds} = run(PurgeWorker, forum)
    assert seconds > 29 * 86_400
    assert Postgres.exists?("fl05-tennis")
  end

  test "immediate deletion needs the subdomain typed as confirmation", %{forum: forum} do
    assert Forums.delete_forum(forum, "operator", immediate: true) ==
             {:error, :confirmation_required}

    assert Forums.delete_forum(forum, "operator", immediate: true, confirm: "other") ==
             {:error, :confirmation_required}

    refute_enqueued(worker: DeleteWorker)
  end

  test "without a final export nothing is deleted", %{forum: forum} do
    Fake.run_result(@backup, 1, "Backup failed")
    {:ok, _} = Forums.delete_forum(forum, "operator")
    assert {:error, _} = run(DeleteWorker, forum, %{"immediate" => false})

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    assert forum.error == "idejo-admin backup exited with 1"
    refute Maintenance.marked?(@host)
    assert container()["Running"]
    refute_enqueued(worker: PurgeWorker)
  end

  test "a deletion can be cancelled during the grace period", %{forum: forum} do
    {:ok, _} = Forums.delete_forum(forum, "operator")
    :ok = run(DeleteWorker, forum, %{"immediate" => false})

    assert {:ok, forum} = Forums.cancel_deletion(Forums.get_forum!(forum.id), "operator")
    assert forum.status == "suspended"
    assert forum.purge_at == nil
    refute_enqueued(worker: PurgeWorker, args: %{"forum_id" => forum.id})

    # Even if a purge job still ran, it does nothing.
    assert :ok = run(PurgeWorker, forum)
    assert Postgres.exists?("fl05-tennis")
  end

  test "a forum that failed to be created is just marked deleted, and its name is free again" do
    Fake.fail(:create_container, {:denied, "test"})
    {:ok, failed} = Forums.create_forum(%{attrs() | "subdomain" => "fl05-chess"}, "operator")
    {:error, _} = run(CreateWorker, failed)

    {:ok, _} = Forums.delete_forum(Forums.get_forum!(failed.id), "operator")
    assert :ok = run(DeleteWorker, failed, %{"immediate" => false})
    assert Forums.get_forum!(failed.id).status == "deleted"
    assert Forums.get_by_subdomain("fl05-chess") == nil

    assert {:ok, _again} =
             Forums.create_forum(%{attrs() | "subdomain" => "fl05-chess"}, "operator")
  end
end
