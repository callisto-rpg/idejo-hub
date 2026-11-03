# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL04SuspendTest do
  @moduledoc """
  FL-04: suspend shows a maintenance page (Caddy, from a mark), keeps data and backups, and
  can be resumed.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, ResumeWorker, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}

  @moduletag req: "FL-04"
  @moduletag :capture_log

  @host "fl04-tennis.idejo.test"

  setup do
    Fake.start()
    healthy(200)
    dir = Application.fetch_env!(:idejo_hub, Maintenance)[:dir]
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      Postgres.drop("fl04-tennis")
      File.rm_rf!(dir)
    end)

    {:ok, forum} =
      Forums.create_forum(
        %{
          "subdomain" => "fl04-tennis",
          "display_name" => "Tennis",
          "owner_email" => "o@example.test"
        },
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    %{forum: Forums.get_forum!(forum.id)}
  end

  defp healthy(status),
    do: Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, status, "{}") end)

  defp run(worker, forum),
    do: perform_job(worker, %{"forum_id" => forum.id, "actor" => "operator"})

  defp running?, do: Fake.state().containers["idejo-forum-fl04-tennis"]["Running"]

  test "suspend marks the host for Caddy, stops the container and keeps everything", %{
    forum: forum
  } do
    assert {:ok, %{step: "suspending"}} = Forums.suspend_forum(forum, "operator")
    assert_enqueued(worker: SuspendWorker, args: %{"forum_id" => forum.id})
    assert :ok = run(SuspendWorker, forum)

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "suspended"
    assert forum.step == nil
    assert Maintenance.marked?(@host)
    refute running?()

    # Data and backups are kept: database, volumes and container all still there.
    assert Postgres.exists?("fl04-tennis")
    assert map_size(Fake.state().volumes) == 2
    assert Map.has_key?(Fake.state().containers, "idejo-forum-fl04-tennis")

    assert [{"forum.suspend", "requested"}, {"forum.suspend", "ok"}] =
             for(
               e <- Audit.for_forum(forum.id),
               e.action == "forum.suspend",
               do: {e.action, e.outcome}
             )
  end

  test "resume starts the container, waits for health, then removes the mark", %{forum: forum} do
    {:ok, forum} = Forums.suspend_forum(forum, "operator")
    :ok = run(SuspendWorker, forum)
    forum = Forums.get_forum!(forum.id)

    assert {:ok, %{step: "resuming"}} = Forums.resume_forum(forum, "operator")
    assert :ok = run(ResumeWorker, forum)

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    refute Maintenance.marked?(@host)
    assert running?()
  end

  test "a resume that never becomes healthy stays suspended, page still shown", %{forum: forum} do
    {:ok, forum} = Forums.suspend_forum(forum, "operator")
    :ok = run(SuspendWorker, forum)
    forum = Forums.get_forum!(forum.id)

    healthy(503)
    {:ok, _} = Forums.resume_forum(forum, "operator")
    assert {:error, "no healthy answer in time"} = run(ResumeWorker, forum)

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "suspended"
    assert forum.step == nil
    assert forum.error == "no healthy answer in time"
    assert Maintenance.marked?(@host)
    refute running?()
  end

  test "a failed stop leaves the forum running and unmarked", %{forum: forum} do
    Fake.fail(:stop_container, {:unreachable, "closed"})
    {:ok, forum} = Forums.suspend_forum(forum, "operator")
    assert {:error, "Docker is unreachable"} = run(SuspendWorker, forum)

    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running"
    refute Maintenance.marked?(@host)
    assert running?()
  end

  test "only a running forum is suspended, only a suspended one resumed, one action at a time",
       %{forum: forum} do
    assert Forums.resume_forum(forum, "operator") == {:error, :invalid_state}
    {:ok, busy} = Forums.suspend_forum(forum, "operator")
    assert Forums.suspend_forum(busy, "operator") == {:error, :invalid_state}
  end

  test "marks are rebuilt from the database at boot", %{forum: forum} do
    {:ok, forum} = Forums.suspend_forum(forum, "operator")
    :ok = run(SuspendWorker, forum)

    Maintenance.unmark(@host)
    Maintenance.mark("stale.idejo.test")
    assert Maintenance.sync() == :ok

    assert Maintenance.marked?(@host)
    refute Maintenance.marked?("stale.idejo.test")
  end

  test "a mark is only ever a host name inside the marks' directory" do
    for bad <- ["..", "../etc", "a/b.idejo.test", "x", "", "-a.idejo.test"] do
      assert_raise ArgumentError, fn -> Maintenance.mark(bad) end
    end
  end
end
