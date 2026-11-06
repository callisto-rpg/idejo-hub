# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.OutsideForum do
  @moduledoc """
  An Idejo server not hosted by this Hub that signs in with its Idejo ID (steward decisions
  2026-11-06; `IdejoHub.Identity.OutsideForums`). Only hashes of its secrets are kept: the
  client secret goes to the forum once, at each registration.

  `status`: `pending` (asked, not proven yet) or `registered`. `listing`: `none`,
  `requested` (the forum asked to be in the directory), `approved` or `refused` (by an
  operator).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @listings ~w(none requested approved refused)

  schema "outside_forums" do
    field :host, :string
    field :display_name, :string
    field :pending_name, :string
    field :status, :string, default: "pending"
    field :app_id, :string
    field :client_id, :string
    field :secret_hash, :binary, redact: true
    field :registration_hash, :binary, redact: true
    field :proof_hash, :binary, redact: true
    field :challenge_expires_at, :utc_datetime
    field :listing, :string, default: "none"
    timestamps(type: :utc_datetime)
  end

  @doc "The directory states a listing can be in."
  def listings, do: @listings
end
