# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.HA05RecreateTest do
  @moduledoc """
  HA-05 / HN-07: settings changed in the Hub reach forums when their containers are made
  again: per forum, or all at once from Settings.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.{Forums, Settings}
  alias IdejoHub.Forums.{CreateWorker, RecreateWorker, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}

  @moduletag req: "HA-05"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    healthy(200)
    on_exit(fn -> for s <- ["rec-a", "rec-b"], do: Postgres.drop(s) end)
    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator, forum: create("rec-a")}
  end

  defp healthy(status),
    do: Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, status, "{}") end)

  defp create(subdomain) do
    {:ok, f} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@x.test"},
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => f.id, "actor" => "op"})
    Forums.get_forum!(f.id)
  end

  defp env(name), do: Fake.state().containers["idejo-forum-#{name}"]["Spec"]["Env"]
  defp running?(name), do: Fake.state().containers["idejo-forum-#{name}"]["Running"]

  defp recreate(forum) do
    {:ok, f} = Forums.recreate_forum(forum, "op")
    assert f.step == "recreating"
    perform_job(RecreateWorker, %{"forum_id" => forum.id, "actor" => "op", "was" => forum.status})
  end

  test "a new SMTP server reaches a running forum when it is recreated", %{forum: forum} do
    refute "IDEJO_SMTP_HOST=smtp.new.test" in env("rec-a")
    {:ok, _} = Settings.update(%{"smtp_host" => "smtp.new.test"}, "op")

    assert :ok = recreate(forum)
    assert "IDEJO_SMTP_HOST=smtp.new.test" in env("rec-a")
    assert running?("rec-a")
    forum = Forums.get_forum!(forum.id)
    assert forum.status == "running" and forum.step == nil
    refute Maintenance.marked?(Forums.host(forum))
    assert map_size(Fake.state().volumes) == 2
  end

  test "a suspended forum is recreated but stays stopped", %{forum: forum} do
    {:ok, _} = Forums.suspend_forum(forum, "op")
    :ok = perform_job(SuspendWorker, %{"forum_id" => forum.id, "actor" => "op"})
    forum = Forums.get_forum!(forum.id)
    {:ok, _} = Settings.update(%{"smtp_host" => "smtp.new.test"}, "op")

    assert :ok = recreate(forum)
    assert "IDEJO_SMTP_HOST=smtp.new.test" in env("rec-a")
    refute running?("rec-a")
    assert Forums.get_forum!(forum.id).status == "suspended"
    assert Maintenance.marked?(Forums.host(forum))
  end

  test "a forum that does not come back stays behind the maintenance page", %{forum: forum} do
    healthy(503)
    assert {:error, _} = recreate(forum)
    forum = Forums.get_forum!(forum.id)
    assert forum.status == "suspended"
    assert Maintenance.marked?(Forums.host(forum))
  end

  test "apply to all forums from Settings: running and suspended, busy ones named", %{
    conn: conn,
    forum: forum
  } do
    other = create("rec-b")
    {:ok, _} = Forums.update_state(other, %{step: "backing_up"})

    {:ok, view, _} = live(conn, ~p"/settings")
    html = view |> element("#apply-all button") |> render_click()
    assert html =~ "Recreating rec-a"
    assert html =~ "Busy, try again later: rec-b"
    assert_enqueued(worker: RecreateWorker, args: %{"forum_id" => forum.id})
    refute_enqueued(worker: RecreateWorker, args: %{"forum_id" => other.id})
  end

  test "the forum page has a Recreate action", %{conn: conn, forum: forum} do
    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")
    view |> element("#recreate") |> render_click()
    assert_enqueued(worker: RecreateWorker, args: %{"forum_id" => forum.id, "was" => "running"})
  end
end
