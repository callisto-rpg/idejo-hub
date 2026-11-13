# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC02CSRFTest do
  @moduledoc """
  SC-02: every forum is "same-site" to the Hub, so SameSite cookies give no protection from a
  forum's pages; a CSRF token is required on every state-changing request. For the Hub: every
  route but GET refuses a request without the session's token, signed in or not; LiveView's
  socket needs the token and the Hub's own origin; and the session cookie cannot be set by a
  subdomain. (Forums: Idejo SP-05 and SP-10.)
  """
  use IdejoHubWeb.ConnCase, async: true

  import IdejoHub.OperatorFixtures

  alias IdejoHubWeb.SessionCookie
  alias Phoenix.Socket.Transport

  @moduletag req: "SC-02"

  @id_host "id.idejo.test"

  # ConnTest skips the CSRF check by default: these requests are checked as a browser's.
  defp checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  defp state_changing_routes do
    for %{verb: verb, path: path, plug: plug} <- IdejoHubWeb.Router.__routes__(),
        verb not in [:get, :head, :options],
        not String.starts_with?(path, "/dev"),
        # The outside forums' JSON API: no session, no cookie (checked below).
        not String.starts_with?(path, "/account/api/"),
        # Forums on the forum network, with their client credentials (Caddy refuses
        # /internal/* from outside): no session either.
        not String.starts_with?(path, "/internal/"),
        do: {verb, path, plug}
  end

  test "SC-02 the outside forums' API takes no session: nothing for a CSRF token to protect" do
    api =
      for %{path: "/account/api/" <> _ = path, verb: verb} <- IdejoHubWeb.Router.__routes__(),
          do: {verb, path}

    # Since Idejo's chat service (steward request 2026-11-10): tickets and unread counts;
    # since 2026-11-13, what is new in the member's other forums.
    assert length(api) == 9
    # Only the API's controller, through the :api pipeline (no :fetch_session, no forgery
    # protection): the router source says so.
    router = File.read!("lib/idejo_hub_web/router.ex")

    assert router =~
             ~s(scope "/account/api", IdejoHubWeb do\n    pipe_through [:identity_host, :api])

    [_, api_pipeline] = Regex.run(~r/pipeline :api do\n(.*?)\n  end/s, router)
    refute api_pipeline =~ "session"

    # The :api pipeline neither fetches nor sets a session.
    conn =
      %{build_conn() | host: @id_host}
      |> put_req_cookie("_idejo_hub_key", "anything")
      |> put("/account/api/listing", %{"listed" => true})

    assert conn.status == 401
    assert get_resp_header(conn, "set-cookie") == []
    refute Map.has_key?(conn.private, :plug_session)
  end

  test "SC-02 every state-changing route refuses a request without the CSRF token", %{
    conn: conn
  } do
    {signed_in, _operator, _password} = sign_in(conn)
    routes = state_changing_routes()
    # Operator sign-in and sign-out, the members' pages: the list is not empty by accident.
    assert {:post, "/sign-in", IdejoHubWeb.SessionController} in routes
    assert {:post, "/account/delete", IdejoHubWeb.AccountController} in routes
    assert {:post, "/sign-out", IdejoHubWeb.DirectoryController} in routes

    for {verb, path, plug} <- routes do
      url = String.replace(path, ~r/:[a-z_]+/, "1")

      base =
        cond do
          String.starts_with?(path, "/account") -> %{build_conn() | host: @id_host}
          # The forums directory's own routes (its sign-out) answer on its host only.
          plug == IdejoHubWeb.DirectoryController -> %{build_conn() | host: "forums.idejo.test"}
          true -> recycle(signed_in)
        end

      assert_error_sent 403, fn ->
        base |> checked() |> dispatch(@endpoint, verb, url, %{})
      end
    end
  end

  test "SC-02 with the page's token, the same request goes through", %{conn: conn} do
    page = get(conn, ~p"/sign-in")

    [token] =
      Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200),
        capture: :all_but_first
      )

    response =
      page
      |> recycle()
      |> checked()
      |> post(~p"/sign-in", %{
        "_csrf_token" => token,
        "session" => %{"email" => "nobody@hub.test", "password" => "x"}
      })

    refute response.status == 403
  end

  test "SC-02 LiveView's socket needs the session (and its CSRF token) and the Hub's origin" do
    for {"/live", Phoenix.LiveView.Socket, opts} <- IdejoHubWeb.Endpoint.__sockets__(),
        transport <- [:websocket, :longpoll] do
      assert {:session, _} = List.keyfind(opts[transport][:connect_info], :session, 0)
    end

    # Origins are checked (never `check_origin: false` outside development) ...
    refute Application.get_env(:idejo_hub, IdejoHubWeb.Endpoint)[:check_origin] == false
    refute File.read!("config/runtime.exs") =~ "check_origin"
    refute File.read!("config/prod.exs") =~ "check_origin"

    # ... against the Hub's own host: a forum's page is refused.
    handler = {Phoenix.LiveView.Socket, nil}

    for {origin, allowed?} <- [{"http://localhost", true}, {"https://tennis.idejo.test", false}] do
      conn =
        build_conn(:get, "/live/websocket")
        |> Plug.Conn.put_req_header("origin", origin)
        |> Transport.check_origin(handler, @endpoint, check_origin: true)

      assert conn.halted == not allowed?, origin
    end
  end

  test "SC-02 in production the session cookie is __Host-: no subdomain may set it" do
    prod = SessionCookie.options(true)
    assert prod[:key] == "__Host-idejo_hub"
    # What browsers require of a __Host- cookie.
    assert prod[:secure] and prod[:path] == "/" and not Keyword.has_key?(prod, :domain)
    assert prod[:same_site] == "Strict" and prod[:http_only]

    # Plain http (here) cannot carry the prefix; the cookie is host-only all the same.
    conn = get(build_conn(), ~p"/sign-in")
    cookie = conn.resp_cookies["_idejo_hub_key"]
    refute Map.has_key?(cookie, :domain)
  end
end
