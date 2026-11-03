# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateForumsAndAuditEntries do
  use Ecto.Migration

  def change do
    # FL-01: one row per forum. Secrets are stored only encrypted (SC-04).
    create table(:forums) do
      add :subdomain, :string, null: false
      add :display_name, :string, null: false
      add :owner_email, :string, null: false
      add :idejo_version, :string, null: false
      add :memory_mb, :integer, null: false
      add :cpus, :float, null: false
      add :status, :string, null: false
      add :step, :string
      add :error, :string
      add :secret_key_base_enc, :binary, null: false
      add :db_password_enc, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:forums, [:subdomain])

    # Every lifecycle action, from the start (SC-07 shows them in milestone 4). Append-only.
    create table(:audit_entries) do
      add :actor, :string, null: false
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :forum_id, :bigint
      add :subdomain, :string
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_entries, [:forum_id, :inserted_at])

    execute(
      """
      CREATE FUNCTION audit_entries_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_entries is append-only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION audit_entries_append_only()"
    )

    execute(
      """
      CREATE TRIGGER audit_entries_append_only
      BEFORE UPDATE OR DELETE ON audit_entries
      FOR EACH ROW EXECUTE FUNCTION audit_entries_append_only()
      """,
      "DROP TRIGGER audit_entries_append_only ON audit_entries"
    )
  end
end
