# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA04ServerTest do
  @moduledoc "HA-04: server page: CPU, memory, disk, PostgreSQL size, running containers."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.Forums
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.Server

  @moduletag req: "HA-04"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    on_exit(fn -> Postgres.drop("ha04-a") end)
    {conn, _operator, _} = sign_in(conn)
    %{conn: conn}
  end

  test "reads load and memory from Linux's own files" do
    assert Server.cpu({:ok, "0.52 0.48 0.40 1/234 5678\n"}).load == [0.52, 0.48, 0.4]
    assert Server.cpu({:error, :enoent}) == :unavailable

    meminfo = "MemTotal:        4000000 kB\nMemFree:  100 kB\nMemAvailable:    1000000 kB\n"
    assert Server.memory({:ok, meminfo}) == %{total: 4_096_000_000, available: 1_024_000_000}
    assert Server.memory({:ok, "garbage"}) == :unavailable
  end

  test "reads disk use with df" do
    assert %{total: total, used: used, available: available} = Server.disk(System.tmp_dir!())
    assert total > 0 and used >= 0 and available >= 0
    assert Server.disk("/no/such/path") == :unavailable
  end

  test "the page shows the server, PostgreSQL sizes and forum containers", %{conn: conn} do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "ha04-a", "display_name" => "A", "owner_email" => "o@a.test"},
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "op"})

    {:ok, view, html} = live(conn, ~p"/server")

    for section <- ~w(cpu memory disk databases containers),
        do: assert(html =~ ~s(id="#{section}"))

    assert view |> element("#container-idejo-forum-ha04-a") |> render() =~ "running"
    assert has_element?(view, "#db-forum_ha04_a")
  end

  test "with the bundle's function, sizes come from it (names and sizes only)" do
    IdejoHub.Repo.query!("""
    CREATE FUNCTION hub_database_sizes() RETURNS TABLE (name name, size bigint)
    LANGUAGE sql STABLE AS $$ SELECT 'from_function'::name, 42::bigint $$
    """)

    assert Server.snapshot().databases == [%{name: "from_function", size: 42}]
  end

  test "Docker unreachable shows as unavailable, not an error" do
    Fake.fail(:list_forum_containers, {:unreachable, "closed"})
    assert Server.snapshot().containers == :unavailable
  end

  test "linked from the header", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(nav[aria-label="Hub"] a[href="/server"]))
  end
end
