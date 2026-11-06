# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Profile do
  @moduledoc """
  An Idejo ID's public face (steward decisions 2026-11-06; `IdejoHub.Identity.Profiles`): the
  username forums give a new member, and a picture (WebP, as Idejo stores avatars). Keyed by
  the provider's subject; the provider's own username stays the email, for signing in.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:subject, :string, autogenerate: false}
  schema "identity_profiles" do
    field :username, :string
    field :picture, :binary, redact: true
    field :picture_key, :string
    timestamps(type: :utc_datetime)
  end
end
