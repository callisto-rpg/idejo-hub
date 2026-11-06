# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumPinned do
  use Ecto.Migration

  # OP-06: a forum pinned to its version is left out of bulk upgrades (OP-05).
  def change do
    alter table(:forums) do
      add :pinned, :boolean, null: false, default: false
    end
  end
end
