# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    # HA-05: operator settings. Secret values are stored encrypted (SC-04).
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :binary, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
