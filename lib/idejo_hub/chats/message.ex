# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Message do
  @moduledoc """
  A message in a chat: open while its author adds to it with Enter, closed after Ctrl+Enter
  (Idejo's growing message, without its patience timers). Markdown and its sanitised HTML.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "chat_messages" do
    belongs_to :chat, IdejoHub.Chats.Chat
    field :author_subject, :string
    field :state, :string, default: "open"
    field :body_md, :string, default: ""
    field :body_html, :string, default: ""
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :edited, :boolean, default: false
    field :deleted_at, :utc_datetime_usec
    belongs_to :reply_to, __MODULE__
    field :source, :string
    has_many :reactions, IdejoHub.Chats.Reaction
  end
end
