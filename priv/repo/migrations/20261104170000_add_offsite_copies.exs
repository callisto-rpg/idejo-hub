# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddOffsiteCopies do
  use Ecto.Migration

  # OP-02: where each backup's encrypted off-server copy is, once uploaded.
  def change do
    for table <- [:forum_exports, :hub_backups] do
      alter table(table) do
        add :offsite_key, :string
        add :offsite_at, :utc_datetime
      end
    end
  end
end
