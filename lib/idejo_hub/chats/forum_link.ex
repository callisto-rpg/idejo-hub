# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.ForumLink do
  @moduledoc """
  What the Hub asks the forums a member joined (steward request 2026-11-10), through Idejo's
  chat service interface (Idejo's CLAUDE.md, Running under Idejo Hub → Chat service), never
  their databases:

    * `forums/1`: the running hosted forums they joined (`identity_joins`) and the outside
      forums they signed in to, by name;
    * `topics/1`: each one's `GET /community/topics?ticket=` (the topics they follow);
    * `import/1`: each one's `GET /community/conversations?ticket=`, copied into chats
      (`IdejoHub.Chats.copy/2`), then `POST /community/conversations/moved`, so the forum
      stops showing them; at most once an hour per member and forum (`chat_imports`), which
      also keeps how many stayed there.

  Hosted forums are asked on the forum network (`http://idejo-forum-<slug>:4000`), outside
  ones at `https://<host>`. Each forum gets four seconds; a forum that does not answer, or
  runs an Idejo without the interface (404), adds nothing.
  """

  import Ecto.Query

  alias IdejoHub.{Chats, Forums, Repo}
  alias IdejoHub.Chats.Tickets
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
          where: j.subject == ^subject and j.state == "joined" and f.status == "running",
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
  Copies `subject`'s private conversations from the forums they joined, those not asked in
  the last hour (`force: true` asks all). `:ok`.
  """
  @spec import(String.t(), keyword()) :: :ok
  def import(subject, opts \\ []) do
    recent = if opts[:force], do: MapSet.new(), else: recent_imports(subject)

    subject
    |> forums()
    |> Enum.reject(&MapSet.member?(recent, &1.host))
    |> each(&import_from(subject, &1))

    :ok
  end

  defp import_from(subject, forum) do
    ticket = Tickets.issue(subject, "conversations", forum.client)

    with {:ok, %{"conversations" => list} = body} when is_list(list) <-
           get(forum, "/community/conversations", ticket) do
      copied =
        for %{"id" => id} = conversation <- list,
            match?({:ok, _}, copy(forum.host, conversation)),
            do: id

      if copied != [], do: post(forum, "/community/conversations/moved", ticket, copied)

      remaining = if is_integer(body["remaining"]), do: body["remaining"], else: 0
      forum_url = if is_binary(body["url"]), do: body["url"], else: forum.url

      Repo.insert_all(
        "chat_imports",
        [
          %{
            subject: subject,
            host: forum.host,
            remaining: remaining,
            forum_url: forum_url,
            imported_at: DateTime.utc_now(:second)
          }
        ],
        on_conflict: {:replace, [:remaining, :forum_url, :imported_at]},
        conflict_target: [:subject, :host]
      )
    end

    nil
  end

  # One conversation a forum sent wrong never stops the others.
  defp copy(host, conversation) do
    Chats.copy(host, conversation)
  rescue
    error ->
      require Logger
      Logger.warning("chat copy from #{host} failed: #{inspect(error.__struct__)}")
      {:error, :unsupported}
  end

  @doc """
  The conversations of `subject`'s that stayed in forums (someone there has no Idejo ID):
  `[%{name:, url:, remaining:}]`, from the last copies.
  """
  @spec remaining(String.t()) :: [map()]
  def remaining(subject) do
    names = Map.new(forums(subject), &{&1.host, &1.name})

    Repo.all(
      from i in "chat_imports",
        where: i.subject == ^subject and i.remaining > 0,
        select: %{host: i.host, url: i.forum_url, remaining: i.remaining}
    )
    |> Enum.filter(&Map.has_key?(names, &1.host))
    |> Enum.map(&Map.put(&1, :name, names[&1.host]))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp recent_imports(subject) do
    since = DateTime.add(DateTime.utc_now(:second), -3600)

    Repo.all(
      from i in "chat_imports",
        where: i.subject == ^subject and i.imported_at > ^since,
        select: i.host
    )
    |> MapSet.new()
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
