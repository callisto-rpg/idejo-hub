# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateIdentityProfiles do
  use Ecto.Migration

  # An idejo ID's public username and picture (steward decisions 2026-11-06), and the outside
  # forums a person signed in to (so they may read and fill that profile).
  def change do
    create table(:identity_profiles, primary_key: false) do
      add :subject, :string, primary_key: true
      add :username, :string
      add :picture, :binary
      add :picture_key, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:identity_profiles, ["lower(username)"],
             name: :identity_profiles_username_index
           )

    create unique_index(:identity_profiles, [:picture_key])

    create table(:outside_joins, primary_key: false) do
      add :subject, :string, primary_key: true

      add :outside_forum_id, references(:outside_forums, on_delete: :delete_all),
        primary_key: true

      add :first_at, :utc_datetime, null: false
    end
  end
end
