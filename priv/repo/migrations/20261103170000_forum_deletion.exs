# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.ForumDeletion do
  use Ecto.Migration

  def change do
    # FL-05: when a forum being deleted is purged (end of the grace period, or now).
    alter table(:forums) do
      add :purge_at, :utc_datetime
    end

    # A deleted forum's subdomain can be used again; its row stays for the record.
    drop unique_index(:forums, [:subdomain])

    create unique_index(:forums, [:subdomain],
             where: "status <> 'deleted'",
             name: :forums_subdomain_index
           )
  end
end
