# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryController do
  @moduledoc """
  The forums directory at `https://forums.<forum domain>/` (steward decisions 2026-11-06):
  running hosted forums the operator has not hidden and approved outside forums, as cards
  with each forum's logo; past ten, a search and pages.

  Each card has **Join** (the forum's sign-in with Idejo ID, `/users/oidc`) or, for a forum
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

  # The forum's logo at Idejo's fixed address (0.2.9); Join is its sign-in with Idejo ID.
  defp card(%{name: name, host: host}, joined) do
    %{
      name: name,
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
