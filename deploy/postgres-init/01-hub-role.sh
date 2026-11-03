#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Runs once, when the PostgreSQL volume is first created. Creates the Hub's own login role
# and database. The role can create databases and roles (one of each per forum, HN-05) but
# is never superuser.

set -eu

: "${HUB_DB_PASSWORD:?HUB_DB_PASSWORD is not set}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v hub_password="$HUB_DB_PASSWORD" <<'SQL'
CREATE ROLE idejo_hub LOGIN CREATEDB CREATEROLE NOSUPERUSER PASSWORD :'hub_password';
CREATE DATABASE idejo_hub OWNER idejo_hub;
REVOKE ALL ON DATABASE idejo_hub FROM PUBLIC;
SQL
