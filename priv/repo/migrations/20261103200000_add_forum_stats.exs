# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumStats do
  use Ecto.Migration

  def change do
    # HA-01: the forum's own figures, from `idejo-admin stats` (Idejo AD-09), never its database.
    alter table(:forums) do
      add :members, :integer
      add :topics, :integer
      add :messages, :integer
      add :database_bytes, :bigint
      add :uploads_bytes, :bigint
      add :stats_at, :utc_datetime
    end
  end
end
