# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Export do
  @moduledoc """
  An export the Hub keeps (FL-06): a standard Idejo backup (`idejo-YYYYMMDD-HHMMSS.tar`),
  stored under `<exports dir>/<subdomain>/`. `kind` is `export` (asked for) or `final`
  (made before a deletion, FL-05).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "forum_exports" do
    field :forum_id, :integer
    field :subdomain, :string
    field :kind, :string
    field :file_name, :string
    field :size, :integer
    field :sha256, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:forum_id, :subdomain, :kind, :file_name, :size, :sha256])
    |> validate_required([:forum_id, :subdomain, :kind, :file_name, :size, :sha256])
    |> validate_inclusion(:kind, ~w(export final))
  end

  @doc "Where an export's file is."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{subdomain: subdomain, file_name: file_name}),
    do: Path.join([dir(), subdomain, file_name])

  @doc "The exports directory (`IDEJO_HUB_EXPORTS_DIR` volume in production)."
  @spec dir() :: String.t()
  def dir, do: Application.fetch_env!(:idejo_hub, __MODULE__)[:dir]
end
