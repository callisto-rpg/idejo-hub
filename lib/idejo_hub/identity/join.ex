# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Join do
  @moduledoc "ID-05: one idejo ID on one forum (the provider's subject, never an email)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(joined leaving left deleting deleted)

  schema "identity_joins" do
    field :subject, :string
    field :state, :string, default: "joined"
    field :first_at, :utc_datetime
    field :last_at, :utc_datetime
    field :changed_at, :utc_datetime
    field :error, :string
    belongs_to :forum, IdejoHub.Forums.Forum
    timestamps(type: :utc_datetime)
  end

  def changeset(join, attrs) do
    join
    |> cast(attrs, [:subject, :forum_id, :state, :first_at, :last_at, :changed_at, :error])
    |> validate_required([:subject, :forum_id, :state, :first_at, :last_at])
    |> validate_inclusion(:state, @states)
  end
end
