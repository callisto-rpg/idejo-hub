# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Forum do
  @moduledoc """
  A forum the Hub runs (FL-01). `status` is its lifecycle state; while a job works on it,
  `step` names the step, and a failed job leaves a short `error` (never a secret).
  Secrets are only kept encrypted (SC-04), bound to `"forum:<subdomain>:<field>"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias IdejoHub.Forums.Subdomain

  @type t :: %__MODULE__{}

  @statuses ~w(creating running failed suspended deleting deleted)

  schema "forums" do
    field :subdomain, :string
    field :display_name, :string
    field :owner_email, :string
    field :idejo_version, :string
    field :memory_mb, :integer
    field :cpus, :float
    field :status, :string, default: "creating"
    field :step, :string
    field :error, :string
    field :secret_key_base_enc, :binary, redact: true
    field :db_password_enc, :binary, redact: true
    field :mail_from, :string
    field :owner_invite, :string
    field :owner_link_enc, :binary, redact: true
    field :purge_at, :utc_datetime
    field :members, :integer
    field :topics, :integer
    field :messages, :integer
    field :database_bytes, :integer
    field :uploads_bytes, :integer
    field :stats_at, :utc_datetime
    field :oidc_app_id, :string
    field :oidc_client_id, :string
    field :oidc_client_secret_enc, :binary, redact: true
    field :local_accounts, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc "The statuses a forum goes through."
  def statuses, do: @statuses

  @doc "What the operator gives to create a forum (FL-01)."
  def create_changeset(forum, attrs) do
    forum
    |> cast(attrs, [
      :subdomain,
      :display_name,
      :owner_email,
      :idejo_version,
      :memory_mb,
      :cpus,
      :mail_from,
      :local_accounts
    ])
    |> update_change(:subdomain, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:owner_email, &String.trim/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([
      :subdomain,
      :display_name,
      :owner_email,
      :idejo_version,
      :memory_mb,
      :cpus
    ])
    |> Subdomain.validate_subdomain(:subdomain)
    |> validate_exclusion(:subdomain, IdejoHub.Settings.reserved_subdomains(),
      message: "is reserved"
    )
    |> validate_length(:display_name, max: 100)
    |> validate_format(:owner_email, ~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/,
      message: "must be an email address"
    )
    |> validate_length(:owner_email, max: 254)
    |> update_change(:mail_from, &String.trim/1)
    |> validate_format(:mail_from, ~r/\A[^@\s<>"]+@[^@\s<>"]+\.[^@\s<>"]+\z/,
      message: "must be an email address"
    )
    |> validate_length(:mail_from, max: 160)
    |> validate_format(:idejo_version, ~r/\A\d+\.\d+\.\d+\z/,
      message: "must be an exact version, for example 0.1.0"
    )
    |> validate_number(:memory_mb, greater_than_or_equal_to: 256, less_than_or_equal_to: 8192)
    |> validate_number(:cpus, greater_than: 0, less_than_or_equal_to: 8)
    |> unique_constraint(:subdomain,
      name: :forums_subdomain_index,
      message: "is already used by another forum"
    )
  end

  @doc "Lifecycle changes, made by the Hub itself."
  def state_changeset(forum, attrs) do
    forum
    |> cast(attrs, [
      :status,
      :step,
      :error,
      :db_password_enc,
      :owner_invite,
      :owner_link_enc,
      :purge_at,
      :idejo_version,
      :members,
      :topics,
      :messages,
      :database_bytes,
      :uploads_bytes,
      :stats_at,
      :oidc_app_id,
      :oidc_client_id,
      :oidc_client_secret_enc,
      :local_accounts
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
