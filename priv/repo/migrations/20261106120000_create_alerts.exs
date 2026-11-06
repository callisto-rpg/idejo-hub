# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateAlerts do
  use Ecto.Migration

  # OP-08: the conditions an alert is open for (a forum down, the disk nearly full), so each
  # is emailed once when it starts and once when it ends.
  def change do
    create table(:alerts) do
      add :key, :string, null: false
      add :subject, :string, null: false
      add :opened_at, :utc_datetime, null: false
      add :notified_at, :utc_datetime
    end

    create unique_index(:alerts, [:key])
  end
end
