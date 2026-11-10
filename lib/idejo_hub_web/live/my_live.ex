# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.MyLive do
  @moduledoc """
  The members' page (steward request 2026-11-10), `my.<forum domain>`: no sidebar, three
  tabs at the top.

    * **Forums** (`/`): the forums the member joined with their Idejo ID
      (`IdejoHub.Chats.ForumLink.forums/1`), as the directory's cards.
    * **Topics** (`/topics`): the topics they follow in those forums, as the forums' expanded
      topic list shows them (excerpt, "Latest messages", writers), the latest active first,
      each naming its forum; asked of the forums once connected
      (`ForumLink.topics/1`, `start_async`).
    * **Chats** (`/chat`): their chats (`IdejoHub.Chats.list/1`), kept current
      (`Chats.subscribe_list/1`). Once connected, their old private conversations are
      copied from the forums (`ForumLink.import/1`, at most hourly per forum), and those
      that stayed in a forum (someone without an Idejo ID) are linked there.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Chats
  alias IdejoHub.Chats.ForumLink

  @impl true
  def mount(_params, _session, socket) do
    subject = socket.assigns.subject
    if connected?(socket), do: Chats.subscribe_list(subject)

    {:ok,
     socket
     |> assign(forums: ForumLink.forums(subject), topics: nil, chats: [], people: %{})
     |> assign(remaining: [], importing?: false, loaded: MapSet.new())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(page_title: title(socket.assigns.live_action)) |> load()}
  end

  defp title(:forums), do: "Forums"
  defp title(:topics), do: "Topics"
  defp title(:chats), do: "Chats"

  defp load(%{assigns: %{live_action: :topics, topics: nil}} = socket) do
    subject = socket.assigns.subject

    if connected?(socket),
      do: start_async(socket, :topics, fn -> ForumLink.topics(subject) end),
      else: socket
  end

  defp load(%{assigns: %{live_action: :chats}} = socket) do
    socket = load_chats(socket)
    subject = socket.assigns.subject

    if connected?(socket) and not MapSet.member?(socket.assigns.loaded, :import) do
      socket
      |> assign(importing?: true, loaded: MapSet.put(socket.assigns.loaded, :import))
      |> start_async(:import, fn -> ForumLink.import(subject) end)
    else
      socket
    end
  end

  defp load(socket), do: socket

  defp load_chats(socket) do
    subject = socket.assigns.subject
    chats = Chats.list(subject)

    assign(socket,
      chats: chats,
      people: Chats.people(Enum.map(chats, & &1.other)),
      remaining: ForumLink.remaining(subject)
    )
  end

  @impl true
  def handle_async(:topics, {:ok, by_forum}, socket) do
    topics =
      for %{forum: forum, topics: topics} <- by_forum, topic <- topics do
        Map.put(topic, "forum", forum)
      end
      |> Enum.sort_by(&(&1["last_activity_at"] || ""), :desc)

    {:noreply, assign(socket, topics: topics)}
  end

  def handle_async(:topics, _failed, socket), do: {:noreply, assign(socket, topics: [])}

  def handle_async(:import, _result, socket),
    do: {:noreply, socket |> assign(importing?: false) |> load_chats()}

  @impl true
  def handle_info(:chats_changed, %{assigns: %{live_action: :chats}} = socket),
    do: {:noreply, load_chats(socket)}

  def handle_info(:chats_changed, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} title="Idejo" wide>
      <div class="flex items-center justify-between gap-2">
        <h1 class="sr-only">{@page_title}</h1>
        <nav aria-label="Your Idejo" class="my-tabs" id="my-tabs">
          <.link patch={~p"/"} aria-current={@live_action == :forums && "page"} id="tab-forums">
            Forums
          </.link>
          <.link patch={~p"/topics"} aria-current={@live_action == :topics && "page"} id="tab-topics">
            Topics
          </.link>
          <.link patch={~p"/chat"} aria-current={@live_action == :chats && "page"} id="tab-chats">
            Chats
          </.link>
        </nav>
        <form action={~p"/sign-out"} method="post">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <button id="my-sign-out" class="btn btn-sm btn-ghost">Sign out</button>
        </form>
      </div>

      <section :if={@live_action == :forums} id="my-forums">
        <p :if={@forums == []} class="my-empty">
          You have not joined a forum with your Idejo ID yet.
          <a href={IdejoHub.Community.directory_url()}>Find a forum</a>
        </p>
        <ul :if={@forums != []} class="directory-grid is-compact">
          <li :for={forum <- @forums}>
            <div class="directory-card is-compact" id={"forum-#{forum.host}"}>
              <a href={forum.url} class="directory-link">
                <img
                  src={forum.url <> "logo"}
                  alt=""
                  class="directory-logo"
                  width="56"
                  height="56"
                  loading="lazy"
                />
                <span class="directory-name">{forum.name}</span>
              </a>
              <a
                href={forum.url}
                class="btn btn-sm btn-primary directory-open"
                aria-label={"Open #{forum.name}"}
              >
                Open
              </a>
            </div>
          </li>
        </ul>
        <p :if={@forums != []} class="my-more">
          <a href={IdejoHub.Community.directory_url()}>Find more forums</a>
        </p>
      </section>

      <section :if={@live_action == :topics} id="my-topics">
        <p :if={@topics == nil} class="my-empty" role="status">Asking your forums…</p>
        <p :if={@topics == []} class="my-empty">
          No followed topics yet. Topics you write in, or follow, in your forums show here.
        </p>
        <ul :if={@topics not in [nil, []]} class="my-topic-list">
          <li :for={topic <- @topics}><.topic_card topic={topic} /></li>
        </ul>
      </section>

      <section :if={@live_action == :chats} id="my-chats">
        <p :if={@importing?} class="my-note" role="status">
          Bringing your private conversations over from your forums…
        </p>
        <p :if={@chats == [] and not @importing?} class="my-empty">
          No chats yet. Open someone's card in a forum and choose “Private Message”.
        </p>
        <ul :if={@chats != []} class="my-chat-list" id="chat-list">
          <li :for={entry <- @chats}>
            <.link
              navigate={~p"/chat/#{entry.chat.id}"}
              class="my-chat-card"
              id={"chat-#{entry.chat.id}"}
            >
              <.person person={@people[entry.other]} />
              <span class="my-chat-main">
                <span class="my-chat-name">{@people[entry.other].name}</span>
                <span :if={entry.last} class="my-chat-last">{excerpt(entry.last)}</span>
              </span>
              <span :if={entry.unread > 0} class="badge badge-primary badge-sm">
                {entry.unread}<span class="sr-only"> unread</span>
              </span>
            </.link>
          </li>
        </ul>
        <div :if={@remaining != []} id="chat-remaining" class="my-note">
          <p>Some conversations stayed in their forum, with people who have no Idejo ID:</p>
          <ul>
            <li :for={r <- @remaining}>
              <a href={r.url}>{r.name}</a> ({conversations(r.remaining)})
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :person, :map, required: true

  @doc "An Idejo ID's picture, or its initial."
  def person(assigns) do
    ~H"""
    <img :if={@person.picture} src={@person.picture} alt="" class="my-avatar" width="40" height="40" />
    <span :if={!@person.picture} class="my-avatar is-initial" aria-hidden="true">
      {String.first(@person.name) |> String.upcase()}
    </span>
    """
  end

  attr :topic, :map, required: true

  # As Idejo's expanded topic row (`TopicComponents.topic_row/1` with a preview): title,
  # badges, category and count; the opening excerpt; "Latest messages"; who wrote.
  defp topic_card(assigns) do
    ~H"""
    <article class="my-topic-card" id={"topic-#{@topic["id"]}"}>
      <header class="my-topic-head">
        <a href={@topic["url"]} class="my-topic-title">{@topic["title"]}</a>
        <span :if={(@topic["unread"] || 0) > 0} class="badge badge-sm badge-primary">
          {@topic["unread"]} new
        </span>
        <span :if={@topic["pinned"]} class="badge badge-sm badge-ghost">Pinned</span>
        <span :if={@topic["state"] == "locked"} class="badge badge-sm badge-ghost">Locked</span>
      </header>
      <p class="my-topic-meta">
        <a href={@topic["forum"].url} class="my-topic-forum">{@topic["forum"].name}</a>
        <span :if={@topic["category"]}>
          › <a href={@topic["category"]["url"]}>{@topic["category"]["name"]}</a>
        </span>
        <span>· {@topic["message_count"]} messages</span>
      </p>
      <p :if={@topic["first"]} class="my-topic-first">{@topic["first"]}</p>
      <div :if={(@topic["latest"] || []) != []} class="my-topic-latest">
        <p class="my-topic-heading">Latest messages</p>
        <ul>
          <li :for={m <- @topic["latest"]}>
            <a href={m["url"]}>
              <span class="font-medium">{m["author"]}</span>
              <span class="my-topic-text">{m["text"]}</span>
            </a>
          </li>
        </ul>
      </div>
      <p :if={(@topic["people"] || []) != []} class="my-topic-people">
        <span class="sr-only">Written by:</span>
        <span :for={p <- @topic["people"]} title={p["name"]} class="my-topic-person">
          <img :if={p["avatar"]} src={p["avatar"]} alt="" width="24" height="24" />
          <span :if={!p["avatar"]} aria-hidden="true">{String.first(p["name"] || "?")}</span>
          <span class="sr-only">{p["name"]}</span>
        </span>
        <span :if={(@topic["people_count"] || 0) > 6} class="my-topic-more">
          +{@topic["people_count"] - 6} more
        </span>
      </p>
    </article>
    """
  end

  defp excerpt(%{deleted_at: %DateTime{}}), do: "Message deleted"

  defp excerpt(message) do
    text = message.body_md |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > 120, do: String.slice(text, 0, 119) <> "…", else: text
  end

  defp conversations(1), do: "1 conversation"
  defp conversations(n), do: "#{n} conversations"
end
