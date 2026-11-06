# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateOutsideForums do
  use Ecto.Migration

  # Outside forums (steward decisions 2026-11-06): Idejo servers not hosted here that sign in
  # with this Hub's Idejo ID, and may ask to be listed in the directory.
  def change do
    create table(:outside_forums) do
      add :host, :string, null: false
      add :display_name, :string, null: false
      add :pending_name, :string
      add :status, :string, null: false, default: "pending"
      add :app_id, :string
      add :client_id, :string
      add :secret_hash, :binary
      add :registration_hash, :binary
      add :proof_hash, :binary
      add :challenge_expires_at, :utc_datetime
      add :listing, :string, null: false, default: "none"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:outside_forums, [:host])
    create unique_index(:outside_forums, [:client_id])
    create unique_index(:outside_forums, [:registration_hash])
  end
end
