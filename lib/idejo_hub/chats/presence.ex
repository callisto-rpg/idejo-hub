# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Presence do
  @moduledoc """
  Who has a chat on screen (steward request 2026-11-10): each view registers under
  `{chat_id, subject}` (a duplicate-key `Registry`). When a view goes, a watcher waits the
  grace (`:chat_grace_ms`, 30 seconds) and, if none of that member's views of the chat is
  left, closes their open message (`IdejoHub.Chats.close_open/2`), as Idejo closes an
  author's open message when their last view of the topic goes (GM-12).
  """

  @grace_ms 30_000

  @doc false
  def child_spec(_arg), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc "Registers the calling view of `chat_id` for `subject`, and watches it."
  @spec join(integer(), String.t()) :: :ok
  def join(chat_id, subject) do
    {:ok, _} = Registry.register(__MODULE__, {chat_id, subject}, nil)
    view = self()

    spawn(fn ->
      ref = Process.monitor(view)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          Process.sleep(Application.get_env(:idejo_hub, :chat_grace_ms, @grace_ms))

          if Registry.lookup(__MODULE__, {chat_id, subject}) == [],
            do: IdejoHub.Chats.close_open(subject, chat_id)
      end
    end)

    :ok
  end
end
