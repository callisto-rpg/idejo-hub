#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# NF-01: the bundle's PostgreSQL holds 30 forums' connections, and those of 10 more past the
# warning (steward decision 2026-11-06), with the Hub's and Zitadel's. Starts the bundle's own
# `db` service under a scratch project, makes 40 forum roles and databases as the Hub does
# (HN-05), then holds their connections at once over the network (dblink): 6 a forum (POOL_SIZE
# 5, set by the Hub, and Oban's listener), 11 as the Hub, 14 as Zitadel (both measured idle) and
# 10 for backups and one-off jobs. Removes everything, pass or fail. Needs Docker; ~20 s.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
project="nf01-$$"
forums=40
per_forum=6

sed -e 's/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=nf01-superuser/' \
  -e 's/^HUB_DB_PASSWORD=.*/HUB_DB_PASSWORD=nf01-hub/' \
  -e 's/^ZITADEL_DB_PASSWORD=.*/ZITADEL_DB_PASSWORD=nf01-zitadel/' \
  "$repo/deploy/.env.example" >"$work/.env"

compose() { docker compose -p "$project" -f "$repo/deploy/docker-compose.yml" --env-file "$work/.env" "$@"; }
cleanup() { compose down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

compose up -d --wait db >/dev/null 2>&1 || { compose logs db; exit 1; }
psql_su() { compose exec -T db psql -U postgres -d "${1:-postgres}" -tAqX -v ON_ERROR_STOP=1; }

echo "max_connections: $(echo 'SHOW max_connections' | psql_su)"

for i in $(seq 1 "$forums"); do
  echo "CREATE ROLE forum_nf01_$i LOGIN PASSWORD 'nf01-forum';
        CREATE DATABASE forum_nf01_$i OWNER forum_nf01_$i;
        REVOKE ALL ON DATABASE forum_nf01_$i FROM PUBLIC;"
done | psql_su >/dev/null

# One superuser session holds every connection, each over TCP as its role (pg_hba's rule).
{
  echo "CREATE EXTENSION dblink;"
  echo "DO \$\$ DECLARE n int := 0; BEGIN"
  hold() { # hold ROLE PASSWORD DATABASE COUNT
    echo "FOR k IN 1..$4 LOOP n := n + 1; PERFORM dblink_connect('c' || n,
      'host=127.0.0.1 user=$1 password=$2 dbname=$3'); END LOOP;"
  }
  for i in $(seq 1 "$forums"); do hold "forum_nf01_$i" nf01-forum "forum_nf01_$i" "$per_forum"; done
  hold idejo_hub nf01-hub idejo_hub 11
  hold zitadel nf01-zitadel zitadel 14
  # Backups (pg_dump), restores and imports (eval with a pool), as one forum at a time.
  hold forum_nf01_1 nf01-forum forum_nf01_1 10
  echo "RAISE NOTICE 'held %', n; END \$\$;"
  echo "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend';"
} | psql_su idejo_hub >"$work/out" 2>&1 || { cat "$work/out"; echo "NF-01: FAILED"; exit 1; }

expected=$((forums * per_forum + 11 + 14 + 10 + 1))
held=$(tail -n 1 "$work/out")
echo "client connections held: $held (expected $expected)"
[ "$held" = "$expected" ] || { echo "NF-01: FAILED"; exit 1; }
echo "NF-01: passed"
