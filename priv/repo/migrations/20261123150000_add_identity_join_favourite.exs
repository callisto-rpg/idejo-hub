# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddIdentityJoinFavourite do
  use Ecto.Migration

  # The inbox's favourite forums (steward request 2026-11-23), per idejo ID and forum.
  def change do
    alter table(:identity_joins) do
      add :favourite, :boolean, null: false, default: false
    end
  end
end
