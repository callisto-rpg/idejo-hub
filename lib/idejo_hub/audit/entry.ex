# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Audit.Entry do
  @moduledoc "One audit log entry (see `IdejoHub.Audit`)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @outcomes ~w(requested ok failed)

  schema "audit_entries" do
    field :actor, :string
    field :action, :string
    field :outcome, :string
    field :forum_id, :integer
    field :subdomain, :string
    field :details, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:actor, :action, :outcome, :forum_id, :subdomain, :details])
    |> validate_required([:actor, :action, :outcome])
    |> validate_inclusion(:outcome, @outcomes)
  end
end
