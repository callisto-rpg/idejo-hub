# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Ticket do
  @moduledoc """
  A ticket the Hub hands one forum to ask about one member (steward request 2026-11-10):
  the forum checks it back with its own client credentials (`IdejoHub.Chats.Tickets`).
  Only its hash is kept.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:token_hash, :binary, autogenerate: false}
  schema "chat_tickets" do
    field :subject, :string
    field :scope, :string
    field :client, :string
    field :expires_at, :utc_datetime
  end
end
