# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumsKind do
  use Ecto.Migration

  # The members' inbox (steward request 2026-11-10): an idejo container like any forum, run
  # in idejo's inbox mode at my.<forum domain>; at most one that is not deleted.
  def change do
    alter table(:forums) do
      add :kind, :string, null: false, default: "forum"
    end

    create unique_index(:forums, [:kind],
             where: "kind = 'inbox' AND status <> 'deleted'",
             name: :forums_one_inbox_index
           )
  end
end
