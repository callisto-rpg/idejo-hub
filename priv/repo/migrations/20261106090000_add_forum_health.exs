# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumHealth do
  use Ecto.Migration

  # OP-07: the health overview, polled every minute (Operations.HealthWorker): the forum's
  # `/health` answer, since when it has been down (for OP-08's alerts), and its container's
  # memory use and limit.
  def change do
    alter table(:forums) do
      add :health, :string
      add :health_at, :utc_datetime
      add :down_since, :utc_datetime
      add :memory_bytes, :bigint
      add :memory_limit_bytes, :bigint
    end
  end
end
