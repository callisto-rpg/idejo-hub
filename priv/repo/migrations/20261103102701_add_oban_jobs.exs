# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Oban's jobs table: lifecycle (FL) and operations (OP) actions run as jobs.
  def up, do: Oban.Migration.up()

  # Drops every Oban table, whatever version was reached.
  def down, do: Oban.Migration.down(version: 1)
end
