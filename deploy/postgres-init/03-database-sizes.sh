#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# HA-04: lets the Hub show how big each database is, without access to any forum database
# (HN-05). A function owned by the superuser returns names and sizes only; the Hub's role
# may run it and nothing more. Runs once, when the PostgreSQL volume is first created.

set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname idejo_hub <<'SQL'
CREATE FUNCTION hub_database_sizes() RETURNS TABLE (name name, size bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate
$$;
REVOKE ALL ON FUNCTION hub_database_sizes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hub_database_sizes() TO idejo_hub;
SQL
