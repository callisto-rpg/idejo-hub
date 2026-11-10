# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Reaction do
  @moduledoc "An emoji an Idejo ID put on a chat message."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "chat_reactions" do
    belongs_to :message, IdejoHub.Chats.Message, primary_key: true
    field :subject, :string, primary_key: true
    field :emoji, :string, primary_key: true
  end
end
