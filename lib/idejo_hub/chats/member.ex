# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Member do
  @moduledoc "An Idejo ID in a chat, and where they read up to."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "chat_members" do
    belongs_to :chat, IdejoHub.Chats.Chat, primary_key: true
    field :subject, :string, primary_key: true
    field :last_read_at, :utc_datetime_usec
  end
end
