# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateOperators do
  use Ecto.Migration

  def change do
    # SC-08: Hub operators. Made from the command line only; sign-in needs a password and a
    # two-factor code (TOTP). The TOTP secret is stored encrypted (SC-04).
    create table(:operators) do
      add :email, :string, null: false
      add :hashed_password, :string, null: false
      add :totp_secret_enc, :binary
      add :totp_enabled_at, :utc_datetime
      # The last TOTP time step used, so a code cannot be used twice.
      add :totp_last_step, :bigint
      add :failed_attempts, :integer, null: false, default: 0
      add :locked_until, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operators, [:email])

    # Signed-in sessions; only a SHA-256 of each token is stored.
    create table(:operator_tokens) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:operator_tokens, [:token_hash])
    create index(:operator_tokens, [:operator_id])
  end
end
