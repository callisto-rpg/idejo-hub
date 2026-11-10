# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Chat do
  @moduledoc "A private conversation between two Idejo IDs (steward request 2026-11-10)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "chats" do
    field :pair_key, :string
    field :last_activity_at, :utc_datetime_usec
    has_many :members, IdejoHub.Chats.Member
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
