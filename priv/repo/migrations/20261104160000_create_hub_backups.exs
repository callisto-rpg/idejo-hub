# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateHubBackups do
  use Ecto.Migration

  # OP-10: dumps of the Hub's own database and the identity provider's.
  def change do
    create table(:hub_backups) do
      add :kind, :string, null: false
      add :file_name, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:hub_backups, [:file_name])
    create index(:hub_backups, [:kind, :inserted_at])
  end
end
