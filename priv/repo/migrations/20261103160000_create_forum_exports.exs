# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateForumExports do
  use Ecto.Migration

  def change do
    # FL-06: exports kept by the Hub (standard idejo backups). Kept after the forum is deleted
    # (FL-05's final export), so no foreign key.
    create table(:forum_exports) do
      add :forum_id, :bigint, null: false
      add :subdomain, :string, null: false
      add :kind, :string, null: false
      add :file_name, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:forum_exports, [:forum_id, :inserted_at])
  end
end
