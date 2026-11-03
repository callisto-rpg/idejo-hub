# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.HA01StatsTest do
  @moduledoc "HA-01: members and disk use from each forum's own `idejo-admin stats`."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.Forums
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.StatsWorker

  @moduletag req: "HA-01"
  @moduletag :capture_log

  @stats ["/app/bin/idejo-admin", "stats"]
  @json ~s({"database_bytes":7000000,"members":42,"messages":900,"topics":31,"uploads_bytes":3485760})

  setup %{conn: conn} do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    on_exit(fn -> for s <- ["stats-a", "stats-b"], do: Postgres.drop(s) end)
    {conn, _op, _} = sign_in(conn)
    %{conn: conn, forum: create("stats-a")}
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

  test "keeps each running forum's figures from idejo-admin stats", %{forum: forum} do
    Fake.exec_result(@stats, {:ok, %{exit_code: 0, output: "=ESOCK WARNING\n" <> @json <> "\n"}})
    assert :ok = perform_job(StatsWorker, %{})

    forum = Forums.get_forum!(forum.id)
    assert {forum.members, forum.topics, forum.messages} == {42, 31, 900}
    assert forum.database_bytes == 7_000_000 and forum.uploads_bytes == 3_485_760
    assert forum.stats_at
    assert {"idejo-forum-stats-a", @stats} in Fake.state().execs
  end

  test "the list shows members and database + uploads", %{conn: conn, forum: forum} do
    Fake.exec_result(@stats, {:ok, %{exit_code: 0, output: @json}})
    :ok = perform_job(StatsWorker, %{})

    {:ok, view, _} = live(conn, ~p"/")
    row = view |> element("#forum-stats-a") |> render()
    assert row =~ ">42<"
    # 7,000,000 + 3,485,760 bytes
    assert row =~ "10.0 MB"
    assert row =~ "database and uploads, from the forum"
    _ = forum
  end

  test "an Idejo without the command keeps no figures; the list shows a dash", %{
    conn: conn,
    forum: forum
  } do
    Fake.exec_result(@stats, {:ok, %{exit_code: 64, output: "Usage: bin/idejo-admin COMMAND"}})
    assert :ok = perform_job(StatsWorker, %{})
    assert Forums.get_forum!(forum.id).members == nil

    {:ok, view, _} = live(conn, ~p"/")
    assert view |> element("#forum-stats-a") |> render() =~ "not reported yet"
  end

  test "output that is not the figures is ignored", %{forum: forum} do
    Fake.exec_result(@stats, {:ok, %{exit_code: 0, output: ~s({"members":-1})}})
    :ok = perform_job(StatsWorker, %{})
    assert Forums.get_forum!(forum.id).members == nil
  end

  test "busy or stopped forums are skipped", %{forum: forum} do
    {:ok, _} = Forums.update_state(forum, %{step: "upgrading"})
    other = create("stats-b")
    {:ok, _} = Forums.update_state(other, %{status: "suspended"})
    Fake.exec_result(@stats, {:ok, %{exit_code: 0, output: @json}})

    :ok = perform_job(StatsWorker, %{})
    refute Enum.any?(Fake.state().execs, fn {_c, cmd} -> cmd == @stats end)
  end

  test "runs every 15 minutes" do
    {Oban.Plugins.Cron, opts} =
      Enum.find(
        Application.fetch_env!(:idejo_hub, Oban)[:plugins],
        &match?({Oban.Plugins.Cron, _}, &1)
      )

    assert {"*/15 * * * *", StatsWorker} in opts[:crontab]
  end
end
