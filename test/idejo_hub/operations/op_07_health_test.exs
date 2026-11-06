# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP07HealthTest do
  @moduledoc """
  OP-07: the health overview. Every minute each running forum's `/health` and memory use
  are checked and kept; the forum list shows them with status, version, last backup and
  disk use.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.Forums
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.HealthWorker

  @moduletag req: "OP-07"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    up(["health-a", "health-b"])
    on_exit(fn -> for s <- ["health-a", "health-b"], do: Postgres.drop(s) end)
    {conn, _op, _} = sign_in(conn)
    %{conn: conn, a: create("health-a"), b: create("health-b")}
  end

  # The forums whose /health answers 200; the others answer 503.
  defp up(subdomains) do
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn ->
      if Enum.any?(subdomains, &(conn.host == "idejo-forum-" <> &1)),
        do: send_resp(conn, 200, "{}"),
        else: send_resp(conn, 503, "{}")
    end)
  end

  defp create(subdomain) do
    {:ok, f} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@x.test"},
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => f.id, "actor" => "op"})
    Forums.get_forum!(f.id)
  end

  test "OP-07 runs every minute, on a queue of its own" do
    crontab =
      Application.fetch_env!(:idejo_hub, Oban)[:plugins] |> Keyword.fetch!(Oban.Plugins.Cron)

    assert {"* * * * *", HealthWorker} in crontab[:crontab]
    assert Application.fetch_env!(:idejo_hub, Oban)[:queues][:health] == 1
  end

  test "OP-07 keeps each running forum's health and memory use", %{a: a, b: b} do
    Fake.put_memory("idejo-forum-health-a", 200 * 1_048_576)
    up(["health-a"])
    assert :ok = perform_job(HealthWorker, %{})

    a = Forums.get_forum!(a.id)
    assert a.health == "ok" and a.health_at != nil and a.down_since == nil
    assert a.memory_bytes == 200 * 1_048_576
    # The limit set on the container (SC-05, the forum's memory_mb).
    assert a.memory_limit_bytes == a.memory_mb * 1_048_576

    b = Forums.get_forum!(b.id)
    assert b.health == "down"
    down_since = b.down_since
    assert down_since

    # Still down a minute later: down since the first check that found it down.
    assert :ok = perform_job(HealthWorker, %{})
    assert Forums.get_forum!(b.id).down_since == down_since

    # Answering again clears it.
    up(["health-a", "health-b"])
    assert :ok = perform_job(HealthWorker, %{})
    b = Forums.get_forum!(b.id)
    assert b.health == "ok" and b.down_since == nil
  end

  test "OP-07 a forum busy with an action is skipped; one not running keeps no health", %{
    a: a,
    b: b
  } do
    :ok = perform_job(HealthWorker, %{})
    {:ok, _} = Forums.update_state(a, %{step: "backup"})
    {:ok, _} = Forums.update_state(Forums.get_forum!(b.id), %{status: "suspended"})
    up([])

    :ok = perform_job(HealthWorker, %{})
    # Busy: left as it was (up), not marked down while it is stopped on purpose.
    assert Forums.get_forum!(a.id).health == "ok"
    b = Forums.get_forum!(b.id)
    assert b.health == nil and b.down_since == nil
  end

  test "OP-07 the forum list shows health and memory, down first when sorted", %{conn: conn} do
    Fake.put_memory("idejo-forum-health-a", 300 * 1_048_576)
    up(["health-a"])
    :ok = perform_job(HealthWorker, %{})

    {:ok, view, _} = live(conn, ~p"/")
    a = view |> element("#forum-health-a") |> render()
    assert a =~ "up"
    assert a =~ "300.0 MB of"
    assert view |> element("#forum-health-b") |> render() =~ "down since"

    html = render_patch(view, ~p"/?sort=health")
    assert :binary.match(html, "forum-health-b") < :binary.match(html, "forum-health-a")

    # Status, version, last backup and disk use stay on the same row.
    assert a =~ "running" and a =~ "never"
  end

  test "OP-07 the list follows each check live", %{conn: conn, b: b} do
    {:ok, view, _} = live(conn, ~p"/")
    refute view |> element("#forum-health-b") |> render() =~ "down since"

    up(["health-a"])
    :ok = perform_job(HealthWorker, %{})
    assert view |> element("#forum-health-b") |> render() =~ "down since"
    assert Forums.get_forum!(b.id).health == "down"
  end
end
