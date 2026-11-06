# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumListed do
  use Ecto.Migration

  # The forums directory (steward decision 2026-11-06): running forums are listed unless the
  # operator hides one.
  def change do
    alter table(:forums) do
      add :listed, :boolean, null: false, default: true
    end
  end
end
