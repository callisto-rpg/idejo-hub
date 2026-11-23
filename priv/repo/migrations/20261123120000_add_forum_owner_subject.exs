# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumOwnerSubject do
  use Ecto.Migration

  # FL-02 (steward request 2026-11-23): a forum given to an existing idejo ID, its owner's
  # subject at the provider; nil for an owner invited by email.
  def change do
    alter table(:forums) do
      add :owner_subject, :string
    end
  end
end
