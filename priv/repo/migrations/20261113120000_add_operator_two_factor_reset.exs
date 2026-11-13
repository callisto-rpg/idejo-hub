# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddOperatorTwoFactorReset do
  use Ecto.Migration

  # SC-08 (steward request 2026-11-13): an operator who lost their two-factor app asks, with
  # their email and password, for a link by email that removes it. Apart from the password
  # reset's link, so neither link does the other's work. Only the SHA-256 is kept.
  def change do
    alter table(:operators) do
      add :two_factor_reset_hash, :binary
      add :two_factor_reset_sent_at, :utc_datetime
    end

    create unique_index(:operators, [:two_factor_reset_hash])
  end
end
