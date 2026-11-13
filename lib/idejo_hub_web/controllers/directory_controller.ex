# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryController do
  @moduledoc """
  The forums directory at `https://forums.<forum domain>/` (steward decisions 2026-11-06):
  running hosted forums the operator has not hidden and approved outside forums, as cards
  with each forum's logo; a search at the top of All Forums (steward request 2026-11-09);
  past ten, pages. `search/2` answers the same search as JSON.

  Each card has **Join** (the forum's sign-in with idejo ID, `/users/oidc`) or, for a forum
  the visitor joined, **Open** (steward request 2026-11-06). The directory learns who is
  looking from the sign-in host (`sign_in/2` → `AccountController.directory/2` →
  `signed_in/2`: a token signed by the Hub, two minutes, bound to this session's `state`),
  kept in its own session for twelve hours. Signed in with joined forums, the first page
  shows them first, above "All forums".
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Community, Identity}
  alias IdejoHub.Identity.Members

  @member_key "directory_member"
  @state_key "directory_state"
  @member_seconds 12 * 3600

  def index(conn, params) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    result = Community.directory_page(params["q"], page)
    subject = member(conn)
    joined = joined(subject)
    cards = Enum.map(result.forums, &card(&1, joined))

    mine =
      if joined != MapSet.new() and result.search == "" and result.page == 1,
        do: joined |> Community.directory_of() |> Enum.map(&card(&1, joined)),
        else: []

    conn
    # Outside forums' logos come from their own hosts: the page's policy allows those shown.
    |> assign(:csp_img_hosts, Enum.map(result.forums, & &1.host) ++ MapSet.to_list(joined))
    |> render(:index,
      forums: cards,
      mine: mine,
      signed_in?: subject != nil,
      result: result,
      browse?: result.listed > Community.per_page(),
      page_title: "Forums"
    )
  end

  @search_limit 5

  @doc """
  `GET /api/forums?q=` (steward request 2026-11-09): the first #{@search_limit} listed
  forums matching `q` (as the page's search; all of them without one), by name, as JSON
  `{"forums": [{"name", "url", "logo", "join"}]}`, for idejo's `!forum` plugin. Public, like
  the page; nobody's own forums, no counts.
  """
  def search(conn, params) do
    q = if is_binary(params["q"]), do: params["q"], else: ""

    forums =
      Community.directory_page(q, 1).forums
      |> Enum.take(@search_limit)
      |> Enum.map(&(&1 |> card(MapSet.new()) |> Map.take([:name, :url, :logo, :join])))

    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> json(%{forums: forums})
  end

  @app_page_size 20

  @doc """
  `GET /api/v1/forums?q=&page=` (HA-10; steward decision 2026-11-10): the directory as JSON
  for the official idejo app, which finds it at `<IDEJO_COMMUNITY_DIRECTORY_URL>api/v1/forums`.
  The same listed, running forums as the page, the same search, #{@app_page_size} a page:
  `{"forums": [{"name", "url", "host", "description", "logo_url", "members"}], "page",
  "pages", "total"}`. `description` is null (forums have none here yet); `members` from the
  last `stats`, null for outside forums. Public, no session or cookie (the `:api`
  pipeline), 120 a minute per address, cached a minute like the page's search.
  """
  def forums(conn, params) do
    case IdejoHub.RateLimit.hit({:directory_api, client_ip(conn)}, 120, 60) do
      :ok ->
        result = Community.directory_page(params["q"], page_number(params), @app_page_size)

        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{
          forums: Enum.map(result.forums, &app_entry/1),
          page: result.page,
          pages: result.pages,
          total: result.total
        })

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(429)
        |> json(%{error: "rate_limited"})
    end
  end

  defp page_number(params) do
    case Integer.parse(to_string(params["page"] || "1")) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp app_entry(%{name: name, host: host} = entry) do
    %{
      name: name,
      url: "https://#{host}/",
      host: host,
      description: nil,
      logo_url: "https://#{host}/logo",
      members: entry[:members]
    }
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  # The forum's logo at idejo's fixed address (0.2.9); Join is its sign-in with idejo ID.
  defp card(%{name: name, host: host} = entry, joined) do
    %{
      name: name,
      members: entry[:members],
      url: "https://#{host}/",
      host: host,
      logo: "https://#{host}/logo",
      join: "https://#{host}/users/oidc",
      joined?: MapSet.member?(joined, host)
    }
  end

  defp joined(nil), do: MapSet.new()

  defp joined(subject) do
    _ = Members.sync()
    Community.joined_hosts(subject)
  end

  @doc "Asks the sign-in host who is looking."
  def sign_in(conn, _params) do
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(@state_key, state)
    |> redirect(
      external:
        Identity.issuer() <> "/account/directory?" <> URI.encode_query(%{"state" => state})
    )
  end

  @doc "The sign-in host's answer: a signed token naming the member and this session's state."
  def signed_in(conn, %{"token" => token}) when is_binary(token) do
    state = get_session(conn, @state_key)
    conn = delete_session(conn, @state_key)

    case Phoenix.Token.verify(
           IdejoHubWeb.Endpoint,
           IdejoHubWeb.AccountController.directory_salt(),
           token,
           max_age: 120
         ) do
      {:ok, %{"sub" => subject, "state" => ^state}} when is_binary(state) ->
        conn
        |> configure_session(renew: true)
        |> put_session(@member_key, %{"sub" => subject, "at" => now()})
        |> redirect(to: ~p"/")

      _ ->
        conn
        |> put_flash(:error, "Signing in did not work. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def signed_in(conn, _params), do: redirect(conn, to: ~p"/")

  def sign_out(conn, _params),
    do: conn |> configure_session(drop: true) |> redirect(to: ~p"/")

  defp member(conn) do
    case get_session(conn, @member_key) do
      %{"sub" => subject, "at" => at} when is_binary(subject) and is_integer(at) ->
        if now() - at <= @member_seconds, do: subject

      _ ->
        nil
    end
  end

  defp now, do: System.system_time(:second)
end
