# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Deletion do
  @moduledoc "ID-06: an Idejo ID being deleted, with its forum accounts first."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:subject, :string, autogenerate: false}
  schema "identity_deletions" do
    field :requested_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :error, :string
  end
end
