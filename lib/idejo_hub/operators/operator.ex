# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operators.Operator do
  @moduledoc "A Hub operator (SC-08). See `IdejoHub.Operators`."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "operators" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :totp_secret_enc, :binary, redact: true
    field :totp_enabled_at, :utc_datetime
    field :totp_last_step, :integer
    field :failed_attempts, :integer, default: 0
    field :locked_until, :utc_datetime
    # HA-07: owners also manage operator accounts.
    field :role, :string, default: "operator"
    # SC-08: the pending password-reset link (its SHA-256) and when it was sent.
    field :reset_token_hash, :binary, redact: true
    field :reset_sent_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @roles ~w(owner operator)

  @doc "HA-07: the roles an operator account can have."
  def roles, do: @roles

  def create_changeset(email, hashed_password, role \\ "operator") do
    %__MODULE__{}
    |> change(
      email: email |> String.trim() |> String.downcase(),
      hashed_password: hashed_password,
      role: role
    )
    |> validate_required([:email, :hashed_password, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_format(:email, ~r/\A[^@\s]+@[^@\s]+\z/, message: "must be an email address")
    |> validate_length(:email, max: 254)
    |> unique_constraint(:email)
  end
end
