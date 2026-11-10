# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ChatLive do
  @moduledoc """
  One chat (steward request 2026-11-10), `my.<forum domain>/chat/<id>`, written like an
  Idejo topic without its patience timers (`IdejoHub.Chats`):

    * the composer is the member's open message: Enter sends the whole text
      (`"commit"`), which the other person sees grow in place; Ctrl+Enter, or Enter three
      times within a second each, sends and closes it, and the box empties for the next one;
      Shift+Enter is a new line (the `.Composer` hook);
    * under each message: Reply (the next message quotes it; with a message open, that one
      is sent and closed first), the reactions (`Chats.reactions/0`), and for one's own
      closed messages Edit (the composer holds it: Enter saves, Ctrl+Enter saves and ends
      the edit, an emptied edit asks to delete it) and Delete;
    * reading the page marks the chat read. A member's open message closes 30 seconds after
      their last view of the chat goes (`IdejoHub.Chats.Presence`).
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Chats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    subject = socket.assigns.subject

    case Chats.get(subject, id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That chat is not yours.") |> push_navigate(to: ~p"/chat")}

      chat ->
        if connected?(socket) do
          Chats.subscribe(chat.id)
          Chats.Presence.join(chat.id, subject)
          Chats.mark_read(subject, chat)
        end

        other = Chats.other(chat, subject)
        people = Chats.people([subject, other])
        open = Chats.open_message(subject, chat)

        {:ok,
         socket
         |> assign(
           chat: chat,
           other: other,
           people: people,
           page_title: people[other].name,
           sent: (open && open.body_md) || "",
           editing: nil,
           reply_to: nil,
           confirm_delete: nil
         )
         |> assign(:messages, Chats.messages(chat))}
    end
  end

  @impl true
  def handle_info({:chat_message, message}, socket) do
    messages = put_message(socket.assigns.messages, message)

    if message.author_subject != socket.assigns.subject,
      do: Chats.mark_read(socket.assigns.subject, socket.assigns.chat)

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:chat_reactions, id, reactions}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^id} = m -> %{m | reactions: reactions}
        m -> m
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  defp put_message(messages, message) do
    if Enum.any?(messages, &(&1.id == message.id)),
      do: Enum.map(messages, &if(&1.id == message.id, do: message, else: &1)),
      else: messages ++ [message]
  end

  @impl true
  def handle_event("commit", %{"body" => body} = params, %{assigns: %{editing: nil}} = socket) do
    break? = params["break"] == true
    opts = [break: break?, reply_to_id: socket.assigns.reply_to]

    case Chats.commit(socket.assigns.subject, socket.assigns.chat, body, opts) do
      {:ok, message} ->
        socket = if message, do: assign(socket, reply_to: nil), else: socket

        {:reply, %{clear: break?},
         assign(socket, sent: if(break?, do: "", else: String.trim_trailing(body)))}

      {:error, :rate_limited} ->
        {:reply, %{error: "You are writing too quickly. Wait a moment."}, socket}

      {:error, _} ->
        {:reply, %{error: "This message could not be sent."}, socket}
    end
  end

  # Editing a closed message: Enter saves, Ctrl+Enter saves and ends the edit.
  def handle_event("commit", %{"body" => body} = params, socket) do
    message = find(socket, socket.assigns.editing)

    case message && Chats.edit(socket.assigns.subject, message, body) do
      {:ok, _} ->
        if params["break"] == true,
          do:
            {:reply, %{clear: true, restore: socket.assigns.sent}, assign(socket, editing: nil)},
          else: {:reply, %{}, socket}

      {:error, :blank} ->
        {:reply, %{}, assign(socket, confirm_delete: message.id)}

      _ ->
        {:reply, %{error: "This message could not be saved."}, assign(socket, editing: nil)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      %{author_subject: subject, state: "closed", deleted_at: nil} = message
      when subject == socket.assigns.subject ->
        {:noreply,
         socket
         |> assign(editing: message.id)
         |> push_event("composer_set", %{text: message.body_md, editing: true})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil, confirm_delete: nil)
     |> push_event("composer_set", %{text: socket.assigns.sent, editing: false})}
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete: (find(socket, id) || %{id: nil}).id)}
  end

  def handle_event("delete", _params, socket) do
    with %{} = message <- find(socket, socket.assigns.confirm_delete),
         {:ok, _} <- Chats.delete_own(socket.assigns.subject, message) do
      :ok
    end

    socket = assign(socket, confirm_delete: nil)

    if socket.assigns.editing,
      do: handle_event("cancel_edit", %{}, socket),
      else: {:noreply, socket}
  end

  def handle_event("keep", _params, socket), do: {:noreply, assign(socket, confirm_delete: nil)}

  # Reply: what the composer holds is sent and closed first, then the next message quotes it.
  def handle_event("reply", %{"id" => id} = params, %{assigns: %{editing: nil}} = socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        body = params["body"] || ""

        if body != "" or Chats.open_message(socket.assigns.subject, socket.assigns.chat),
          do: Chats.commit(socket.assigns.subject, socket.assigns.chat, body, break: true)

        {:reply, %{clear: true}, assign(socket, reply_to: message.id, sent: "")}
    end
  end

  def handle_event("reply", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_reply", _params, socket), do: {:noreply, assign(socket, reply_to: nil)}

  def handle_event("react", %{"id" => id, "emoji" => emoji}, socket) do
    if message = find(socket, id),
      do: Chats.toggle_reaction(socket.assigns.subject, message, emoji)

    {:noreply, socket}
  end

  defp find(_socket, nil), do: nil

  defp find(socket, id) do
    id = if is_binary(id), do: String.to_integer(id), else: id
    Enum.find(socket.assigns.messages, &(&1.id == id))
  rescue
    ArgumentError -> nil
  end

  # Message bodies are HTML the Hub rendered and sanitised itself (`Chats.Markdown`), or a
  # forum's, sanitised again when copied.
  # sobelow_skip ["XSS.Raw"]
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} title="Idejo" wide>
      <nav aria-label="Your Idejo" class="my-tabs" id="my-tabs">
        <.link navigate={~p"/"} id="tab-forums">Forums</.link>
        <.link navigate={~p"/topics"} id="tab-topics">Topics</.link>
        <.link navigate={~p"/chat"} aria-current="page" id="tab-chats">Chats</.link>
      </nav>
      <h1 class="my-chat-title" id="chat-title">
        <IdejoHubWeb.MyLive.person person={@people[@other]} />
        {@people[@other].name}
      </h1>

      <ol class="chat-messages" id="chat-messages">
        <li
          :for={message <- @messages}
          :if={not (message.author_subject == @subject and message.state == "open")}
          id={"message-#{message.id}"}
          class={[
            "chat-message",
            message.author_subject == @subject && "is-mine",
            @editing == message.id && "is-editing"
          ]}
        >
          <div class="chat-message-head">
            <IdejoHubWeb.MyLive.person person={@people[message.author_subject]} />
            <span class="font-medium">{@people[message.author_subject].name}</span>
            <time datetime={DateTime.to_iso8601(message.opened_at)} class="chat-time">
              {Calendar.strftime(message.opened_at, "%Y-%m-%d %H:%M")} UTC
            </time>
            <span :if={message.edited && !message.deleted_at} class="chat-edited">edited</span>
            <span :if={message.state == "open"} class="sr-only">(still being written)</span>
          </div>
          <p :if={message.reply_to && !message.deleted_at} class="chat-reply-quote">
            <a href={"#message-#{message.reply_to.id}"}>
              Replying to {@people[message.reply_to.author_subject].name}: {quote_excerpt(
                message.reply_to
              )}
            </a>
          </p>
          <p :if={message.deleted_at} class="chat-deleted">Message deleted</p>
          <div :if={!message.deleted_at} class="chat-body message-body">
            {Phoenix.HTML.raw(message.body_html)}
          </div>
          <div :if={!message.deleted_at} class="chat-reactions">
            <button
              :for={{emoji, count, mine?} <- reaction_counts(message, @subject)}
              type="button"
              class={["chat-reaction", mine? && "is-mine"]}
              aria-pressed={to_string(mine?)}
              phx-click="react"
              phx-value-id={message.id}
              phx-value-emoji={emoji}
            >
              {emoji} {count}
            </button>
          </div>
          <div :if={!message.deleted_at} class="chat-actions">
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              id={"message-#{message.id}-reply"}
              phx-click={JS.dispatch("idejo:reply", to: "#composer", detail: %{id: message.id})}
            >
              Reply
            </button>
            <details class="chat-react">
              <summary class="btn btn-xs btn-ghost">React</summary>
              <span class="chat-react-choices">
                <button
                  :for={emoji <- IdejoHub.Chats.reactions()}
                  type="button"
                  phx-click="react"
                  phx-value-id={message.id}
                  phx-value-emoji={emoji}
                  aria-label={"React with #{emoji}"}
                >
                  {emoji}
                </button>
              </span>
            </details>
            <button
              :if={message.author_subject == @subject and message.state == "closed"}
              type="button"
              class="btn btn-xs btn-ghost"
              id={"message-#{message.id}-edit"}
              phx-click="edit"
              phx-value-id={message.id}
            >
              Edit
            </button>
            <button
              :if={message.author_subject == @subject and message.state == "closed"}
              type="button"
              class="btn btn-xs btn-ghost"
              id={"message-#{message.id}-delete"}
              phx-click="ask_delete"
              phx-value-id={message.id}
            >
              Delete
            </button>
          </div>
        </li>
      </ol>

      <div
        :if={@confirm_delete}
        id="confirm-delete"
        class="chat-confirm"
        role="alertdialog"
        aria-labelledby="confirm-delete-text"
      >
        <p id="confirm-delete-text">Delete this message? This cannot be undone.</p>
        <button type="button" class="btn btn-sm btn-error" phx-click="delete" id="confirm-delete-yes">Delete</button>
        <button type="button" class="btn btn-sm" phx-click="keep">Keep it</button>
      </div>

      <div :if={@reply_to} id="replying-to" class="chat-replying">
        Replying to {quote_excerpt(Enum.find(@messages, &(&1.id == @reply_to)))}
        <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_reply">Cancel reply</button>
      </div>
      <div :if={@editing} id="editing-note" class="chat-replying">
        Editing your message. Enter saves, Ctrl+Enter saves and ends the edit.
        <button type="button" class="btn btn-xs btn-ghost" phx-click="cancel_edit">Cancel edit</button>
      </div>

      <div
        id="composer"
        class="chat-composer"
        phx-hook=".Composer"
        phx-update="ignore"
        data-sent={@sent}
      >
        <label for="composer-input" class="sr-only">Your message</label>
        <textarea
          id="composer-input"
          rows="3"
          autocomplete="off"
          class="textarea w-full"
          placeholder="Enter to send · Ctrl+Enter to start a new message · Shift+Enter for a new line"
        ></textarea>
        <p class="chat-composer-status" aria-live="polite"></p>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
        // The composer is the open message (as Idejo's): Enter sends the whole text and keeps
        // it; Ctrl+Enter, or three Enters within a second each, sends and closes it.
        const ENTER_RUN_MS = 1000
        export default {
          mounted() {
            this.box = this.el.querySelector("textarea")
            this.status = this.el.querySelector(".chat-composer-status")
            this.box.value = this.el.dataset.sent || ""
            this.run = []
            this.box.addEventListener("keydown", e => this.onKey(e))
            this.box.addEventListener("input", () => { this.run = [] })
            this.el.addEventListener("idejo:reply", e => {
              this.pushEvent("reply", {id: e.detail.id, body: this.box.value}, reply => this.answer(reply))
              this.box.focus()
            })
            this.handleEvent("composer_set", ({text}) => {
              this.box.value = text
              this.box.focus()
              this.box.setSelectionRange(text.length, text.length)
            })
          },
          onKey(e) {
            if (e.key === "Escape") { this.pushEvent("cancel_edit", {}); return }
            if (e.key !== "Enter" || e.shiftKey || e.isComposing) return
            e.preventDefault()
            const now = Date.now()
            this.run = this.run.filter(t => now - t < ENTER_RUN_MS)
            this.run.push(now)
            let brk = e.ctrlKey || e.metaKey
            if (this.run.length >= 3) { brk = true; this.run = [] }
            this.send(brk)
          },
          send(brk) {
            this.pushEvent("commit", {body: this.box.value, break: brk}, reply => this.answer(reply))
          },
          answer(reply) {
            if (reply.error) { this.status.textContent = reply.error; return }
            this.status.textContent = ""
            if (reply.clear) this.box.value = reply.restore || ""
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp reaction_counts(message, subject) do
    message.reactions
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, list} ->
      {emoji, length(list), Enum.any?(list, &(&1.subject == subject))}
    end)
    |> Enum.sort_by(fn {emoji, _, _} ->
      Enum.find_index(Chats.reactions(), &(&1 == emoji)) || 99
    end)
  end

  defp quote_excerpt(nil), do: ""
  defp quote_excerpt(%{deleted_at: %DateTime{}}), do: "a deleted message"

  defp quote_excerpt(message) do
    text = message.body_md |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > 80, do: String.slice(text, 0, 79) <> "…", else: text
  end
end
