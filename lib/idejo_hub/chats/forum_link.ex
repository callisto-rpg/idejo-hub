# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.ForumLink do
  @moduledoc """
  What the Hub asks the forums a member joined for the members' inbox (steward request
  2026-11-10; Idejo's inbox mode, `IdejoHubWeb.InboxServiceController`), through Idejo's
  chat service interface (Idejo's CLAUDE.md, Running under Idejo Hub → Chat service), never
  their databases:

    * `forums/1`: the running hosted forums they joined (`identity_joins`; the inbox itself
      left out) and the outside forums they signed in to, by name;
    * `topics/1`: each one's `GET /community/topics?ticket=` (the topics they follow);
    * `conversations/1`: each one's `GET /community/conversations?ticket=` (their private
      conversations the inbox copies), and `moved/3`, `POST /community/conversations/moved`.

  Hosted forums are asked on the forum network (`http://idejo-forum-<slug>:4000`), outside
  ones at their public address only. Each forum gets four seconds; a forum that does not
  answer, or runs an Idejo without the interface (404), adds nothing.
  """

  import Ecto.Query

  alias IdejoHub.Chats.Tickets
  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Hosting.ForumContainer
  alias IdejoHub.Identity.{Join, OutsideForum, Proof}

  @timeout 4_000

  @doc """
  The forums `subject` joined, by name: `[%{name:, host:, url:, base:, client:}]`, `base`
  where the Hub asks it.
  """
  @spec forums(String.t()) :: [map()]
  def forums(subject) do
    hosted =
      Repo.all(
        from j in Join,
          join: f in assoc(j, :forum),
          where:
            j.subject == ^subject and j.state == "joined" and f.status == "running" and
              f.kind == "forum",
          select: f
      )
      |> Enum.map(fn %Forum{} = f ->
        host = Forums.host(f)

        %{
          name: f.display_name,
          host: host,
          url: "https://#{host}/",
          base: "http://#{ForumContainer.name(f.subdomain)}:4000",
          client: "forum:#{f.id}"
        }
      end)

    outside =
      Repo.all(
        from o in OutsideForum,
          join: j in "outside_joins",
          on: j.outside_forum_id == o.id,
          where: j.subject == ^subject and o.status == "registered",
          select: o
      )
      |> Enum.map(fn o ->
        %{
          name: o.display_name || o.host,
          host: o.host,
          url: "https://#{o.host}/",
          base: "https://#{o.host}",
          outside: true,
          client: "outside:#{o.id}"
        }
      end)

    Enum.sort_by(hosted ++ outside, &String.downcase(&1.name))
  end

  @doc """
  The topics `subject` follows, forum by forum: `[%{forum:, topics: [map]}]`, forums with
  none (or no answer) left out. Topics are the forums' JSON as they sent it.
  """
  @spec topics(String.t()) :: [map()]
  def topics(subject) do
    subject
    |> forums()
    |> each(fn forum ->
      ticket = Tickets.issue(subject, "topics", forum.client)

      case get(forum, "/community/topics", ticket) do
        {:ok, %{"topics" => topics}} when is_list(topics) and topics != [] ->
          %{forum: forum, topics: Enum.filter(topics, &is_map/1)}

        _ ->
          nil
      end
    end)
  end

  @doc """
  `subject`'s private conversations in each forum, as the forums sent them:
  `[%{forum:, body:}]`, `body` the forum's JSON (`conversations`, `remaining`, `url`).
  """
  @spec conversations(String.t()) :: [map()]
  def conversations(subject) do
    subject
    |> forums()
    |> each(fn forum ->
      ticket = Tickets.issue(subject, "conversations", forum.client)

      case get(forum, "/community/conversations", ticket) do
        {:ok, %{"conversations" => list} = body} when is_list(list) -> %{forum: forum, body: body}
        _ -> nil
      end
    end)
  end

  @doc """
  Tells the forum at `host` (one `subject` joined) that the inbox copied those of their
  conversations: it stops showing them. `:ok`, or `:error`.
  """
  @spec moved(String.t(), String.t(), [String.t()]) :: :ok | :error
  def moved(subject, host, ids) when is_list(ids) do
    case Enum.find(forums(subject), &(&1.host == host)) do
      nil ->
        :error

      forum ->
        ticket = Tickets.issue(subject, "conversations", forum.client)

        case post(forum, "/community/conversations/moved", ticket, ids) do
          {:ok, %{status: 200}} -> :ok
          _ -> :error
        end
    end
  end

  @doc """
  How many of `subject`'s chats in the members' inbox have something new (a forum's sidebar
  count): asked of the inbox on the forum network, `GET /community/inbox-unread?subject=`,
  with the inbox's own client credentials, which only the Hub and the inbox know. 0 without
  a running inbox or an answer.
  """
  @spec inbox_unread(String.t()) :: non_neg_integer()
  def inbox_unread(subject) do
    with %Forum{status: "running"} = inbox <- Forums.inbox(),
         {:ok, secret} <- Forums.secret(inbox, :oidc_client_secret),
         {:ok, %{status: 200, body: %{"unread" => n}}} when is_integer(n) and n >= 0 <-
           Req.get(
             base_request(
               "http://#{ForumContainer.name(inbox.subdomain)}:4000/community/inbox-unread",
               auth: {:basic, inbox.oidc_client_id <> ":" <> secret},
               params: [subject: subject],
               receive_timeout: 2_000
             )
           ) do
      n
    else
      _ -> 0
    end
  end

  defp each(forums, fun) do
    forums
    |> Task.async_stream(fun, timeout: @timeout + 1_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, result} -> [result]
      _ -> []
    end)
  end

  defp get(forum, path, ticket) do
    with {:ok, request} <- request(forum, path),
         {:ok, %{status: 200, body: %{} = body}} <- Req.get(request, params: [ticket: ticket]) do
      {:ok, body}
    else
      _ -> :error
    end
  end

  defp post(forum, path, ticket, ids) do
    with {:ok, request} <- request(forum, path),
         do: Req.post(request, json: %{ticket: ticket, ids: ids})
  end

  # An outside forum is asked at the address its name resolves to, checked public (as its
  # registration's proof, `IdejoHub.Identity.Proof`), never a redirect: a forum cannot
  # point the Hub at its own network.
  defp request(%{outside: true, host: host}, path) do
    resolver =
      Application.get_env(:idejo_hub, :chats_resolver, &Proof.getaddrs/1)

    with {:ok, [address | _] = addresses} <- resolver.(host),
         true <- Enum.all?(addresses, &Proof.public?/1) do
      ip = address |> :inet.ntoa() |> to_string()
      url_host = if tuple_size(address) == 8, do: "[#{ip}]", else: ip

      {:ok,
       base_request("https://#{url_host}" <> path,
         headers: [{"host", host}],
         connect_options: [hostname: host, timeout: @timeout]
       )}
    else
      _ -> :error
    end
  end

  defp request(forum, path), do: {:ok, base_request(forum.base <> path, [])}

  defp base_request(url, opts) do
    [
      url: url,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout],
      retry: false,
      redirect: false
    ]
    |> Keyword.merge(opts)
    |> Req.new()
    |> Req.merge(Application.get_env(:idejo_hub, :chats_req_options, []))
  end
end
