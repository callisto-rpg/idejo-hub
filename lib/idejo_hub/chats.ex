# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats do
  @moduledoc """
  Chats (steward request 2026-11-10): private conversations between two Idejo IDs, held by
  the Hub (`my.<forum domain>/chat`) rather than by each forum. Forums on Idejo with a chat
  service (`IDEJO_CHAT_URL`) send their members here, and the Hub copies each member's old
  private conversations from the forums they joined (`IdejoHub.Chats.ForumLink`).

  Messages grow as in an Idejo topic, without its patience timers: the composer sends the
  author's whole message after each Enter (`commit/4`), which opens a message or rewrites the
  author's open one; Ctrl+Enter (`break: true`) closes it, so the next Enter opens a new one.
  One open message per author and chat (a unique index). A closed message is edited by its
  author (`edit/3`; marked edited, no versions kept) or deleted (`delete_own/2`). Unread:
  messages by the other person opened after `chat_members.last_read_at` (a growing message
  counts once). Events go to `"chat:<id>"` (`{:chat_message, message}`,
  `{:chat_reactions, message_id, reactions}`) and `"chats:<subject>"` (`:chats_changed`).
  """

  import Ecto.Query

  alias IdejoHub.Chats.{Chat, Markdown, Member, Message, Reaction}
  alias IdejoHub.{Community, RateLimit, Repo}
  alias IdejoHub.Identity.{Profile, Profiles}

  @pubsub IdejoHub.PubSub

  @doc "The reactions offered under a message."
  @spec reactions() :: [String.t()]
  def reactions, do: ~w(👍 ❤️ 😄 😮 😢 🎉)

  ## Events

  @doc "Subscribes the caller to one chat's events."
  def subscribe(chat_id), do: Phoenix.PubSub.subscribe(@pubsub, "chat:#{chat_id}")

  @doc "Subscribes the caller to changes in `subject`'s list of chats."
  def subscribe_list(subject), do: Phoenix.PubSub.subscribe(@pubsub, "chats:" <> subject)

  defp broadcast(%Message{} = message) do
    Phoenix.PubSub.broadcast(@pubsub, "chat:#{message.chat_id}", {:chat_message, message})

    for subject <- member_subjects(message.chat_id),
        do: Phoenix.PubSub.broadcast(@pubsub, "chats:" <> subject, :chats_changed)

    :ok
  end

  ## People

  @doc """
  How `subjects` show: `%{subject => %{name:, picture:}}`, their Idejo ID profile's
  username and picture (`IdejoHub.Identity.Profiles`), or "Idejo ID member".
  """
  @spec people([String.t()]) :: %{String.t() => %{name: String.t(), picture: String.t() | nil}}
  def people(subjects) do
    profiles =
      Repo.all(from p in Profile, where: p.subject in ^Enum.uniq(subjects))
      |> Map.new(&{&1.subject, &1})

    Map.new(subjects, fn subject ->
      profile = profiles[subject] || %Profile{subject: subject}

      {subject,
       %{
         name: profile.username || "Idejo ID member",
         picture: Profiles.picture_url(profile)
       }}
    end)
  end

  ## Chats

  @doc """
  The chat between `sender` and `recipient`, made when there is none: `{:ok, chat}`. Only
  between two different Idejo IDs that share a forum (`Community.joined_hosts/1`), so a
  stranger's subject leads nowhere; ten new chats an hour per sender.
  """
  @spec start(String.t(), term()) :: {:ok, Chat.t()} | {:error, :forbidden | :rate_limited}
  def start(sender, recipient)
      when is_binary(sender) and is_binary(recipient) and sender != recipient and
             recipient != "" do
    shared? =
      not MapSet.disjoint?(Community.joined_hosts(sender), Community.joined_hosts(recipient))

    cond do
      chat = between(sender, recipient) -> {:ok, chat}
      not shared? -> {:error, :forbidden}
      RateLimit.hit({:chat_start, sender}, 10, 3600) != :ok -> {:error, :rate_limited}
      true -> {:ok, ensure(sender, recipient)}
    end
  end

  def start(_sender, _recipient), do: {:error, :forbidden}

  defp pair_key(a, b), do: Enum.join(Enum.sort([a, b]), "\n")

  defp between(a, b), do: Repo.get_by(Chat, pair_key: pair_key(a, b))

  # The pair's chat, made when there is none (two at once make one).
  defp ensure(a, b) do
    now = DateTime.utc_now()

    {:ok, chat} =
      Repo.transact(fn ->
        Repo.insert_all(
          Chat,
          [%{pair_key: pair_key(a, b), last_activity_at: now, inserted_at: now}],
          on_conflict: :nothing,
          conflict_target: :pair_key
        )

        chat = between(a, b)

        Repo.insert_all(
          Member,
          [%{chat_id: chat.id, subject: a}, %{chat_id: chat.id, subject: b}],
          on_conflict: :nothing,
          conflict_target: [:chat_id, :subject]
        )

        {:ok, chat}
      end)

    chat
  end

  @doc "The chat with that id, when `subject` is in it; else nil."
  @spec get(String.t(), term()) :: Chat.t() | nil
  def get(subject, id) when is_binary(subject) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        Repo.one(
          from c in Chat,
            join: m in Member,
            on: m.chat_id == c.id and m.subject == ^subject,
            where: c.id == ^id
        )

      _ ->
        nil
    end
  end

  @doc "The other person in the chat, for `subject`."
  @spec other(Chat.t(), String.t()) :: String.t() | nil
  def other(%Chat{pair_key: key}, subject),
    do: key |> String.split("\n") |> Enum.find(&(&1 != subject))

  defp member_subjects(chat_id),
    do: Repo.all(from m in Member, where: m.chat_id == ^chat_id, select: m.subject)

  @doc """
  `subject`'s chats, the latest active first:
  `[%{chat:, other:, last: message | nil, unread: n}]`.
  """
  @spec list(String.t()) :: [map()]
  def list(subject) do
    chats =
      Repo.all(
        from c in Chat,
          join: m in Member,
          on: m.chat_id == c.id and m.subject == ^subject,
          order_by: [desc: c.last_activity_at, desc: c.id]
      )

    ids = Enum.map(chats, & &1.id)
    unread = unread_counts(subject, ids)

    last =
      Repo.all(
        from msg in Message,
          where: msg.chat_id in ^ids and is_nil(msg.deleted_at),
          distinct: msg.chat_id,
          order_by: [asc: msg.chat_id, desc: msg.opened_at, desc: msg.id]
      )
      |> Map.new(&{&1.chat_id, &1})

    for chat <- chats,
        do: %{
          chat: chat,
          other: other(chat, subject),
          last: last[chat.id],
          unread: Map.get(unread, chat.id, 0)
        }
  end

  @doc "How many of `subject`'s chats have unread messages: the forums' sidebar count."
  @spec unread_count(String.t()) :: non_neg_integer()
  def unread_count(subject) do
    ids = Repo.all(from m in Member, where: m.subject == ^subject, select: m.chat_id)
    subject |> unread_counts(ids) |> map_size()
  end

  defp unread_counts(_subject, []), do: %{}

  defp unread_counts(subject, chat_ids) do
    Repo.all(
      from msg in Message,
        join: m in Member,
        on: m.chat_id == msg.chat_id and m.subject == ^subject,
        where:
          msg.chat_id in ^chat_ids and msg.author_subject != ^subject and
            is_nil(msg.deleted_at) and
            (is_nil(m.last_read_at) or msg.opened_at > m.last_read_at),
        group_by: msg.chat_id,
        select: {msg.chat_id, count(msg.id)}
    )
    |> Map.new()
  end

  @doc "Marks everything in the chat read for `subject`."
  @spec mark_read(String.t(), Chat.t()) :: :ok
  def mark_read(subject, %Chat{id: id}) do
    Repo.update_all(from(m in Member, where: m.chat_id == ^id and m.subject == ^subject),
      set: [last_read_at: DateTime.utc_now()]
    )

    Phoenix.PubSub.broadcast(@pubsub, "chats:" <> subject, :chats_changed)
    :ok
  end

  ## Messages

  @limit 300

  @doc "The chat's last #{@limit} messages, oldest first, with reactions."
  @spec messages(Chat.t()) :: [Message.t()]
  def messages(%Chat{id: id}) do
    from(m in Message,
      where: m.chat_id == ^id,
      order_by: [desc: m.opened_at, desc: m.id],
      limit: @limit,
      preload: [:reactions, :reply_to]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "`subject`'s open message in the chat, or nil."
  @spec open_message(String.t(), Chat.t()) :: Message.t() | nil
  def open_message(subject, %Chat{id: id}) do
    Repo.one(
      from m in Message,
        where: m.chat_id == ^id and m.author_subject == ^subject and m.state == "open"
    )
  end

  @doc """
  Commits `text`, the author's whole open message as the composer shows it: Enter, or with
  `break: true` Ctrl+Enter, which closes it. `{:ok, message}`; `{:ok, nil}` for an empty
  Enter with nothing open. `reply_to_id:` names, when this opens a message, the chat's
  message it replies to; a message open already closes first for it.
  """
  @spec commit(String.t(), Chat.t(), String.t(), keyword()) ::
          {:ok, Message.t() | nil} | {:error, :rate_limited | :forbidden}
  def commit(subject, %Chat{} = chat, text, opts \\ []) when is_binary(text) do
    text = String.trim_trailing(text)
    break? = Keyword.get(opts, :break, false)

    with :ok <- member(subject, chat),
         :ok <- RateLimit.hit({:chat_commit, subject}, 120, 60) do
      result =
        Repo.transact(fn ->
          Repo.one!(from c in Chat, where: c.id == ^chat.id, lock: "FOR UPDATE")
          open = open_message(subject, chat)
          commit_locked(subject, chat, open, text, break?, reply_to(chat, opts[:reply_to_id]))
        end)

      with {:ok, messages} <- result do
        Enum.each(messages, &broadcast/1)
        {:ok, List.last(messages)}
      end
    end
  end

  # A reply closes the open message and opens a new one; an empty Ctrl+Enter only closes it;
  # otherwise the open message is rewritten, or a new one opened.
  defp commit_locked(subject, chat, open, text, break?, reply_to) do
    cond do
      open && reply_to ->
        {:ok, closed} = close_locked(open)
        {:ok, opened} = open_new(subject, chat, text, break?, reply_to)
        {:ok, [closed, opened]}

      open && text == "" && break? ->
        with {:ok, closed} <- close_locked(open), do: {:ok, [closed]}

      open ->
        with {:ok, message} <- rewrite(open, text, break?), do: {:ok, [message]}

      text == "" ->
        {:ok, []}

      true ->
        with {:ok, message} <- open_new(subject, chat, text, break?, reply_to),
             do: {:ok, [message]}
    end
  end

  defp member(subject, chat),
    do: if(get(subject, chat.id), do: :ok, else: {:error, :forbidden})

  defp reply_to(_chat, nil), do: nil

  defp reply_to(chat, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        Repo.one(
          from m in Message,
            where: m.id == ^id and m.chat_id == ^chat.id and is_nil(m.deleted_at)
        )

      _ ->
        nil
    end
  end

  defp open_new(subject, chat, text, break?, reply_to) do
    now = DateTime.utc_now()

    message =
      Repo.insert!(%Message{
        chat_id: chat.id,
        author_subject: subject,
        state: if(break?, do: "closed", else: "open"),
        body_md: text,
        body_html: Markdown.to_html(text),
        opened_at: now,
        closed_at: if(break?, do: now),
        reply_to_id: reply_to && reply_to.id
      })

    Repo.update_all(from(c in Chat, where: c.id == ^chat.id), set: [last_activity_at: now])
    {:ok, Repo.preload(message, [:reactions, :reply_to])}
  end

  defp rewrite(open, text, break?) do
    now = DateTime.utc_now()

    fields =
      [body_md: text, body_html: Markdown.to_html(text)] ++
        if(break?, do: [state: "closed", closed_at: now], else: [])

    with {:ok, message} <- open |> Ecto.Changeset.change(fields) |> Repo.update(),
         do: {:ok, Repo.preload(message, [:reactions, :reply_to])}
  end

  defp close_locked(message) do
    with {:ok, message} <-
           message
           |> Ecto.Changeset.change(state: "closed", closed_at: DateTime.utc_now())
           |> Repo.update(),
         do: {:ok, Repo.preload(message, [:reactions, :reply_to])}
  end

  @doc """
  Closes `subject`'s open message in the chat (they left it: no page of theirs shows it
  any more). An empty one is deleted.
  """
  @spec close_open(String.t(), integer()) :: :ok
  def close_open(subject, chat_id) do
    case Repo.one(
           from m in Message,
             where: m.chat_id == ^chat_id and m.author_subject == ^subject and m.state == "open"
         ) do
      nil ->
        :ok

      %Message{body_md: ""} = message ->
        {:ok, deleted} =
          message
          |> Ecto.Changeset.change(
            state: "closed",
            closed_at: DateTime.utc_now(),
            deleted_at: DateTime.utc_now()
          )
          |> Repo.update()

        broadcast(Repo.preload(deleted, [:reactions, :reply_to]))

      message ->
        {:ok, closed} = close_locked(message)
        broadcast(closed)
    end

    :ok
  end

  @doc """
  Edits a closed message, as its author: `{:ok, message}`, marked edited;
  `{:error, :blank}` for no text, `{:error, :forbidden}` for anyone else's, an open or a
  deleted one.
  """
  @spec edit(String.t(), Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :blank | :forbidden}
  def edit(subject, %Message{} = message, text) when is_binary(text) do
    text = String.trim_trailing(text)

    cond do
      not own_closed?(subject, message) ->
        {:error, :forbidden}

      String.trim(text) == "" ->
        {:error, :blank}

      text == message.body_md ->
        {:ok, message}

      true ->
        {:ok, message} =
          message
          |> Ecto.Changeset.change(body_md: text, body_html: Markdown.to_html(text), edited: true)
          |> Repo.update()

        message = Repo.preload(message, [:reactions, :reply_to], force: true)
        broadcast(message)
        {:ok, message}
    end
  end

  @doc "Deletes a closed message, as its author: readers see that it was deleted."
  @spec delete_own(String.t(), Message.t()) :: {:ok, Message.t()} | {:error, :forbidden}
  def delete_own(subject, %Message{} = message) do
    if own_closed?(subject, message) do
      {:ok, message} =
        message |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      message = Repo.preload(message, [:reactions, :reply_to], force: true)
      broadcast(message)
      {:ok, message}
    else
      {:error, :forbidden}
    end
  end

  defp own_closed?(subject, message),
    do:
      message.author_subject == subject and message.state == "closed" and
        is_nil(message.deleted_at)

  @doc "The chat's message with that id, for `subject` in it; else nil."
  @spec get_message(String.t(), Chat.t(), term()) :: Message.t() | nil
  def get_message(_subject, %Chat{id: chat_id}, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        Repo.one(
          from m in Message,
            where: m.id == ^id and m.chat_id == ^chat_id,
            preload: [:reactions, :reply_to]
        )

      _ ->
        nil
    end
  end

  @doc "Adds `emoji` (one of `reactions/0`) to the message, or takes it back."
  @spec toggle_reaction(String.t(), Message.t(), String.t()) :: :ok | {:error, :forbidden}
  def toggle_reaction(subject, %Message{} = message, emoji) do
    if emoji in reactions() and is_nil(message.deleted_at) and
         RateLimit.hit({:chat_react, subject}, 60, 60) == :ok do
      key = [message_id: message.id, subject: subject, emoji: emoji]

      case Repo.get_by(Reaction, key) do
        nil -> Repo.insert!(struct(Reaction, key))
        reaction -> Repo.delete!(reaction)
      end

      reactions = Repo.all(from r in Reaction, where: r.message_id == ^message.id)

      Phoenix.PubSub.broadcast(
        @pubsub,
        "chat:#{message.chat_id}",
        {:chat_reactions, message.id, reactions}
      )

      :ok
    else
      {:error, :forbidden}
    end
  end

  ## Copies from forums

  @doc """
  Copies one of a forum's private conversations (`IdejoHub.Chats.ForumLink`): its messages
  join the pair's chat in time order, each once (`source`: the forum's host and the message's
  id), closed, with their reactions. Only two-person conversations of known subjects.
  `{:ok, copied}` or `{:error, :unsupported}`.
  """
  @spec copy(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, :unsupported}
  def copy(host, %{"subjects" => [a, b], "messages" => messages})
      when is_binary(a) and is_binary(b) and a != b and is_list(messages) do
    chat = ensure(a, b)
    rows = copied_rows(host, chat, [a, b], messages)

    {count, inserted} =
      Repo.insert_all(Message, rows,
        on_conflict: :nothing,
        conflict_target: :source,
        returning: [:id, :source]
      )

    ids = Map.new(inserted, &{&1.source, &1.id})

    Repo.insert_all(Reaction, copied_reactions(host, ids, [a, b], messages),
      on_conflict: :nothing
    )

    case rows |> Enum.map(& &1.opened_at) |> Enum.max(DateTime, fn -> nil end) do
      nil -> :ok
      latest -> caught_up(chat, latest)
    end

    {:ok, count}
  end

  def copy(_host, _conversation), do: {:error, :unsupported}

  defp copied_rows(host, chat, subjects, messages) do
    for %{"id" => id, "author" => author, "opened_at" => opened_at} = m <- messages,
        author in subjects,
        {:ok, at, _} <- [DateTime.from_iso8601(to_string(opened_at))],
        at = %{at | microsecond: {elem(at.microsecond, 0), 6}} do
      %{
        chat_id: chat.id,
        author_subject: author,
        state: "closed",
        body_md: to_string(m["body_md"]),
        body_html: Markdown.sanitize(m["body_html"]),
        opened_at: at,
        closed_at: at,
        edited: m["edited"] == true,
        source: host <> "/" <> to_string(id)
      }
    end
  end

  defp copied_reactions(host, ids, subjects, messages) do
    for %{"id" => id, "reactions" => list} <- messages,
        is_list(list),
        message_id = ids[host <> "/" <> to_string(id)],
        %{"char" => char, "subject" => subject} <- list,
        char in reactions(),
        subject in subjects,
        do: %{message_id: message_id, subject: subject, emoji: char}
  end

  # The chat is as recent as its newest copied message, and copied history is not news:
  # both have read up to it.
  defp caught_up(chat, latest) do
    Repo.update_all(
      from(c in Chat, where: c.id == ^chat.id and c.last_activity_at < ^latest),
      set: [last_activity_at: latest]
    )

    Repo.update_all(
      from(m in Member, where: m.chat_id == ^chat.id and is_nil(m.last_read_at)),
      set: [last_read_at: latest]
    )
  end
end
