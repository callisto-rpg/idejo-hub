# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddOperatorPasswordReset do
  use Ecto.Migration

  # SC-08: an operator who forgot their password asks for a link by email. Only the link's
  # SHA-256 is kept, with when it was sent; one at a time, used once.
  def change do
    alter table(:operators) do
      add :reset_token_hash, :binary
      add :reset_sent_at, :utc_datetime
    end

    create unique_index(:operators, [:reset_token_hash])
  end
end
