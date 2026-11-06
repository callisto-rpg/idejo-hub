# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddOperatorRoles do
  use Ecto.Migration

  # HA-07: operator accounts have a role, owner or operator. Operators made before roles were
  # made by whoever runs the server: they become owners.
  def up do
    alter table(:operators) do
      add :role, :string, null: false, default: "operator"
    end

    execute "UPDATE operators SET role = 'owner'"
    create constraint(:operators, :operators_role_check, check: "role IN ('owner', 'operator')")
  end

  def down do
    alter table(:operators) do
      remove :role
    end
  end
end
