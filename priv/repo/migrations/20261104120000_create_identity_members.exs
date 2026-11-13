# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateIdentityMembers do
  use Ecto.Migration

  # ID-05, ID-06: which forums each idejo ID has signed in to (read from the provider's
  # sign-in events, never a forum's database), what they chose, and identity deletions.
  def change do
    create table(:identity_joins) do
      add :subject, :string, null: false
      add :forum_id, references(:forums, on_delete: :delete_all), null: false
      # joined | leaving | left | deleting | deleted
      add :state, :string, null: false, default: "joined"
      add :first_at, :utc_datetime, null: false
      add :last_at, :utc_datetime, null: false
      add :changed_at, :utc_datetime
      add :error, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:identity_joins, [:subject, :forum_id])

    create table(:identity_deletions, primary_key: false) do
      add :subject, :string, primary_key: true
      add :requested_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :error, :string
    end

    # One row: where the sign-in events were read up to, and the Hub's own client for the
    # members' pages (its secret encrypted, SC-04).
    create table(:identity_state, primary_key: false) do
      add :id, :integer, primary_key: true
      add :events_since, :utc_datetime_usec
      add :account_app_id, :string
      add :account_client_id, :string
      add :account_client_secret_enc, :binary
    end
  end
end
