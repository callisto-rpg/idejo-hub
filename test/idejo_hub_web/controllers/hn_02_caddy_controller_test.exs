# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HN02CaddyControllerTest do
  @moduledoc "HN-02: Caddy's on-demand TLS check and the page for unreachable forums."
  use IdejoHubWeb.ConnCase, async: true

  alias IdejoHub.Forums

  @moduletag req: "HN-02"

  defp forum(subdomain, status) do
    {:ok, forum} =
      Forums.create_forum(
        %{
          "subdomain" => subdomain,
          "display_name" => "Club <#{subdomain}>",
          "owner_email" => "o@#{subdomain}.idejo.test"
        },
        "operator"
      )

    {:ok, forum} = Forums.update_state(forum, %{status: status})
    forum
  end

  defp ask(conn, domain), do: get(conn, ~p"/internal/caddy/ask?#{[domain: domain]}")

  describe "ask" do
    test "yes for existing, non-deleted forums", %{conn: conn} do
      for {sub, status} <- [
            {"hn02-run", "running"},
            {"hn02-new", "creating"},
            {"hn02-pause", "suspended"}
          ] do
        forum(sub, status)
        assert ask(conn, "#{sub}.idejo.test").status == 200, sub
      end

      forum("hn02-gone", "deleted")
      assert ask(conn, "hn02-gone.idejo.test").status == 404
    end

    test "yes for the Hub's own host", %{conn: conn} do
      host = Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)[:url][:host]
      assert ask(conn, host).status == 200
    end

    test "no for anything else", %{conn: conn} do
      forum("hn02-run", "running")

      for domain <- [
            "unknown.idejo.test",
            "a.hn02-run.idejo.test",
            "hn02-run.idejo.test.evil.example",
            "hn02-run.other.test",
            "www.idejo.test",
            ""
          ] do
        assert ask(conn, domain).status == 404, domain
      end

      assert get(conn, ~p"/internal/caddy/ask").status == 400
    end

    test "case does not matter", %{conn: conn} do
      forum("hn02-run", "running")
      assert ask(conn, "HN02-Run.IDEJO.test").status == 200
    end
  end

  describe "forum-unavailable" do
    defp unavailable(conn, host) do
      conn |> put_req_header("x-idejo-forum-host", host) |> get(~p"/internal/forum-unavailable")
    end

    test "says why, escaped, with 503", %{conn: conn} do
      forum("hn02-pause", "suspended")
      conn = unavailable(conn, "hn02-pause.idejo.test")
      assert conn.status == 503
      assert conn.resp_body =~ "paused for maintenance"
      assert conn.resp_body =~ "Club &lt;hn02-pause&gt;"
      refute conn.resp_body =~ "<script"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "being set up, or down", %{conn: conn} do
      forum("hn02-new", "creating")
      forum("hn02-run", "running")
      assert unavailable(conn, "hn02-new.idejo.test").resp_body =~ "being set up"
      assert unavailable(conn, "hn02-run.idejo.test").resp_body =~ "temporarily unavailable"
    end

    test "404 for deleted or unknown forums", %{conn: conn} do
      forum("hn02-gone", "deleted")
      assert unavailable(conn, "hn02-gone.idejo.test").status == 404
      assert unavailable(conn, "nobody.idejo.test").status == 404
    end
  end
end
