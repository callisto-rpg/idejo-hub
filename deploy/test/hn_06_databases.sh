#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# HN-06: the Hub and the identity provider each have their own database. Starts the bundle's
# own `db` service (deploy/docker-compose.yml, its postgres-init scripts) under a scratch
# project, then connects over the network as each role, as the Hub and Zitadel do: each opens
# its own database and never the other's, nor a forum's or the server's, and neither is
# superuser. Removes everything, pass or fail. Needs Docker; about 20 seconds.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
project="hn06-$$"

# The variables the bundle needs; only the database passwords matter here.
sed -e 's/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=hn06-superuser/' \
  -e 's/^HUB_DB_PASSWORD=.*/HUB_DB_PASSWORD=hn06-hub/' \
  -e 's/^ZITADEL_DB_PASSWORD=.*/ZITADEL_DB_PASSWORD=hn06-zitadel/' \
  "$repo/deploy/.env.example" >"$work/.env"

compose() { docker compose -p "$project" -f "$repo/deploy/docker-compose.yml" --env-file "$work/.env" "$@"; }
cleanup() { compose down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

fails=0
check() { # check NAME CONDITION...
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}

compose up -d --wait db >/dev/null 2>&1 || { compose logs db; exit 1; }

# Over TCP, as the Hub and Zitadel connect (pg_hba's network rule), never the local socket.
sql() { # sql ROLE PASSWORD DATABASE QUERY
  compose exec -T -e PGPASSWORD="$2" db \
    psql -h 127.0.0.1 -U "$1" -d "$3" -tAqX -v ON_ERROR_STOP=1 -c "$4" 2>/dev/null
}
opens() { [ "$(sql "$1" "$2" "$3" 'SELECT 1')" = 1 ]; }
refused() { ! opens "$@"; }
owner() { [ "$(sql postgres hn06-superuser postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$1'")" = "$2" ]; }
not_superuser() { [ "$(sql postgres hn06-superuser postgres "SELECT rolsuper FROM pg_roles WHERE rolname = '$1'")" = f ]; }

# A forum's database, as the Hub makes them (HN-05), to show neither reaches one.
sql postgres hn06-superuser postgres "CREATE ROLE forum_hn06 LOGIN PASSWORD 'hn06-forum'" >/dev/null
sql postgres hn06-superuser postgres "CREATE DATABASE forum_hn06 OWNER forum_hn06" >/dev/null
sql postgres hn06-superuser postgres "REVOKE ALL ON DATABASE forum_hn06 FROM PUBLIC" >/dev/null

check "the Hub's database is its own" owner idejo_hub idejo_hub
check "Zitadel's database is its own" owner zitadel zitadel
check "the Hub's role is not superuser" not_superuser idejo_hub
check "Zitadel's role is not superuser" not_superuser zitadel

check "the Hub opens its database" opens idejo_hub hn06-hub idejo_hub
check "Zitadel opens its database" opens zitadel hn06-zitadel zitadel

check "the Hub cannot open Zitadel's database as itself" refused idejo_hub hn06-hub zitadel
check "Zitadel cannot open the Hub's database" refused zitadel hn06-zitadel idejo_hub
check "the Hub cannot open a forum's database" refused idejo_hub hn06-hub forum_hn06
check "Zitadel cannot open a forum's database" refused zitadel hn06-zitadel forum_hn06
check "the Hub cannot open the server's database" refused idejo_hub hn06-hub postgres
check "Zitadel cannot open the server's database" refused zitadel hn06-zitadel postgres

if [ "$fails" -gt 0 ]; then
  echo "HN-06: $fails check(s) failed"
  exit 1
fi
echo "HN-06: passed"
