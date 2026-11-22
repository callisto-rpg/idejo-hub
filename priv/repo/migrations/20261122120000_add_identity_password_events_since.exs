# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddIdentityPasswordEventsSince do
  use Ecto.Migration

  # Steward request 2026-11-22: the Hub emails its own notice when an idejo ID's password
  # changes, reading the provider's events from where it last read.
  def change do
    alter table(:identity_state) do
      add :password_events_since, :utc_datetime_usec
    end
  end
end
