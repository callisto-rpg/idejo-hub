# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.InboxServiceController do
  @moduledoc """
  The members' inbox asks here (steward request 2026-11-10; idejo's inbox mode at
  `my.<forum domain>`, `IdejoHub.Forums.inbox/0`), on the forum network at
  `/internal/community/inbox/*`, with HTTP Basic: the inbox's own client id and secret
  (`IdejoHub.Community.inbox_client?/2`); 401 for anyone else. The Hub relays to the forums
  the member joined (`IdejoHub.Chats.ForumLink`), with tickets:

    * `GET topics?subject=` → `{"forums": [{"name", "url", "topics"}]}`;
    * `GET conversations?subject=` → `{"forums": [{"name", "host", "url", "remaining",
      "conversations"}]}`;
    * `POST conversations/moved` `{"subject", "host", "ids"}` → `{"moved"}`;
    * `POST settings` `{"subject", "settings"}` → `{"forums": [{"name", "host", "answered",
      "saved", "failed"}]}`: "Save for all forums" (steward request 2026-11-13);
    * `POST favourite` `{"subject", "host", "favourite"}` → `{"favourite"}`: the Forums
      tab's "Mark as favourite" (steward request 2026-11-23; `Members.set_favourite/3`);
    * `POST leave` `{"subject", "host"}` → `{"state": "leaving"}`: its "Leave forum", the
      account and messages kept (`Members.leave/3`, `:leave`).

  A forum the member is not in answers 404 `{"error": "not_joined"}`.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Chats.ForumLink
  alias IdejoHub.Forums
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity.Members

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

  def settings(conn, %{"subject" => subject, "settings" => %{} = settings})
      when is_binary(subject) and subject != "" do
    forums = ForumLink.save_settings(subject, settings)
    conn |> put_resp_header("cache-control", "no-store") |> json(%{forums: forums})
  end

  def settings(conn, _params), do: bad_request(conn)

  def favourite(conn, %{"subject" => subject, "host" => host, "favourite" => favourite})
      when is_binary(subject) and subject != "" and is_binary(host) and is_boolean(favourite) do
    with %Forum{kind: "forum"} = forum <- Forums.for_host(host),
         {:ok, join} <- Members.set_favourite(subject, forum.id, favourite) do
      json(conn, %{favourite: join.favourite})
    else
      _ -> not_joined(conn)
    end
  end

  def favourite(conn, _params), do: bad_request(conn)

  def leave(conn, %{"subject" => subject, "host" => host})
      when is_binary(subject) and subject != "" and is_binary(host) do
    with %Forum{kind: "forum"} = forum <- Forums.for_host(host),
         {:ok, join} <- Members.leave(subject, forum.id, :leave) do
      json(conn, %{state: join.state})
    else
      {:error, reason} when reason in [:busy, :deleting] ->
        conn |> put_status(409) |> json(%{error: to_string(reason)})

      _ ->
        not_joined(conn)
    end
  end

  def leave(conn, _params), do: bad_request(conn)

  defp not_joined(conn), do: conn |> put_status(404) |> json(%{error: "not_joined"})

  defp bad_request(conn), do: conn |> put_status(400) |> json(%{error: "bad request"})
end
