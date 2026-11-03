#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# HN-05: a forum's role can reach only its own database. Runs once, when the PostgreSQL volume
# is first created (after 01-hub-role.sh).
#
# 1. No database is open to PUBLIC. The Hub revokes PUBLIC on every forum database it creates
#    (IdejoHub.Hosting.Postgres); this does the same for the server's own databases.
# 2. Over the network, every role may open only the database with its own name (`sameuser`):
#    idejo_hub → idejo_hub, forum_<slug> → forum_<slug>. The superuser keeps local socket
#    access for maintenance.

set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
SQL

# The image's entrypoint has already written its catch-all network rule; narrow it.
sed -i 's/^host all all all scram-sha-256$/host sameuser all all scram-sha-256/' "$PGDATA/pg_hba.conf"
grep -q '^host sameuser all all scram-sha-256$' "$PGDATA/pg_hba.conf" || {
  echo "02-forum-isolation.sh: the pg_hba.conf rule to narrow was not found" >&2
  exit 1
}
