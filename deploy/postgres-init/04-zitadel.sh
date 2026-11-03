#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# ID-01: Zitadel's own role and database on the shared server, like a forum's (HN-05): it can
# open only its own database (pg_hba `sameuser`, 02-forum-isolation.sh). Runs once, on a new
# volume; deploy/install.sh does the same on an existing one.

set -eu

: "${ZITADEL_DB_PASSWORD:?ZITADEL_DB_PASSWORD is not set}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v zitadel_password="$ZITADEL_DB_PASSWORD" <<'SQL'
CREATE ROLE zitadel LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'zitadel_password';
CREATE DATABASE zitadel OWNER zitadel;
REVOKE ALL ON DATABASE zitadel FROM PUBLIC;
SQL
