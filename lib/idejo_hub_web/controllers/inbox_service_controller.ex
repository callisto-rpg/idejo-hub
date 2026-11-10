# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.InboxServiceController do
  @moduledoc """
  The members' inbox asks here (steward request 2026-11-10; Idejo's inbox mode at
  `my.<forum domain>`, `IdejoHub.Forums.inbox/0`), on the forum network at
  `/internal/community/inbox/*`, with HTTP Basic: the inbox's own client id and secret
  (`IdejoHub.Community.inbox_client?/2`); 401 for anyone else. The Hub relays to the forums
  the member joined (`IdejoHub.Chats.ForumLink`), with tickets:

    * `GET topics?subject=` → `{"forums": [{"name", "url", "topics"}]}`;
    * `GET conversations?subject=` → `{"forums": [{"name", "host", "url", "remaining",
      "conversations"}]}`;
    * `POST conversations/moved` `{"subject", "host", "ids"}` → `{"moved"}`.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Chats.ForumLink

  plug :inbox_only

  defp inbox_only(conn, _opts) do
    with {id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         true <- IdejoHub.Community.inbox_client?(id, secret) do
      conn
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  def topics(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    forums =
      for %{forum: forum, topics: topics} <- ForumLink.topics(subject),
          do: %{name: forum.name, url: forum.url, topics: topics}

    conn |> put_resp_header("cache-control", "no-store") |> json(%{forums: forums})
  end

  def topics(conn, _params), do: bad_request(conn)

  def conversations(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    forums =
      for %{forum: forum, body: body} <- ForumLink.conversations(subject) do
        %{
          name: forum.name,
          host: forum.host,
          url: if(is_binary(body["url"]), do: body["url"], else: forum.url),
          remaining: if(is_integer(body["remaining"]), do: body["remaining"], else: 0),
          conversations: body["conversations"]
        }
      end

    conn |> put_resp_header("cache-control", "no-store") |> json(%{forums: forums})
  end

  def conversations(conn, _params), do: bad_request(conn)

  def moved(conn, %{"subject" => subject, "host" => host, "ids" => ids})
      when is_binary(subject) and is_binary(host) and is_list(ids) do
    case ForumLink.moved(subject, host, Enum.filter(ids, &is_binary/1)) do
      :ok -> json(conn, %{moved: length(ids)})
      :error -> conn |> put_status(502) |> json(%{error: "the forum did not answer"})
    end
  end

  def moved(conn, _params), do: bad_request(conn)

  defp bad_request(conn), do: conn |> put_status(400) |> json(%{error: "bad request"})
end
