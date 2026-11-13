# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ChatServiceController do
  @moduledoc """
  Idejo's chat service, as forums ask it (steward request 2026-11-10; Idejo's
  `Idejo.Community.Chat`), with HTTP Basic: the asking forum's own client id and secret
  (hosted at `/internal/community/chats/*` on the forum network, outside forums at
  `/account/api/chats/*`):

    * `POST …/tickets` `{"ticket"}` → `{"subject", "scope"}`: what a ticket the Hub handed
      that forum names (`IdejoHub.Chats.Tickets`); 404 for any other;
    * `GET …/unread?subject=` → `{"unread"}`: how many of that member's chats have
      something new in the members' inbox (asked of it), only about someone who joined that
      forum;
    * `GET …/activity?subject=` → `{"unread", "mentions"}`: what is new for that member in
      the topics they follow in their other forums (steward request 2026-11-13: the dot on
      the forum's logo), summed, about someone who joined that forum (`ForumLink.activity/2`).

  401 without a forum's credentials.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Chats.{ForumLink, Tickets}
  alias IdejoHub.Community

  def ticket(conn, params) do
    with {:ok, client} <- client(conn) do
      case Tickets.redeem(params["ticket"], client) do
        {:ok, %{subject: subject, scope: scope}} -> json(conn, %{subject: subject, scope: scope})
        :error -> conn |> put_status(404) |> json(%{error: "unknown ticket"})
      end
    end
  end

  def unread(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    with {client_id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         true <- Community.member_of_client?(client_id, secret, subject) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{unread: ForumLink.inbox_unread(subject)})
    else
      _ -> unauthorized(conn)
    end
  end

  def unread(conn, _params), do: unauthorized(conn)

  def activity(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    with {client_id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         true <- Community.member_of_client?(client_id, secret, subject),
         key when is_binary(key) <- Community.client_key(client_id, secret) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(ForumLink.activity(subject, key))
    else
      _ -> unauthorized(conn)
    end
  end

  def activity(conn, _params), do: unauthorized(conn)

  defp client(conn) do
    with {client_id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         key when is_binary(key) <- Community.client_key(client_id, secret) do
      {:ok, key}
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> json(%{error: "unauthorized"})
end
