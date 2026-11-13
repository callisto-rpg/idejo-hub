#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Hub NF-02: an idle forum instance uses under 200 MB of memory. Runs one forum as the Hub
# runs them (the version new forums start on, POOL_SIZE 5, the default memory and CPU
# limits: all read from the Hub's config), sets it up, loads what a visitor loads once, leaves
# it idle, then reads its memory as `docker stats` does (usage less inactive page cache) and
# fails if any reading reaches 200 MB. idejo's own method (its docs/load-testing.md, NF-12).
#
# Needs Docker; about 12 minutes. IDEJO_IMAGE overrides the image (default
# ghcr.io/callisto-rpg/idejo:<IDEJO_DEFAULT_VERSION's default>); IDLE_SECONDS (300) and
# READINGS (10, 30 s apart) shorten it. Removes everything, pass or fail.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
version=$(sed -n 's/.*IDEJO_DEFAULT_VERSION", "\([0-9.]*\)".*/\1/p' "$repo/config/runtime.exs")
memory_mb=$(sed -n 's/^ *default_memory_mb: \([0-9]*\),.*/\1/p' "$repo/config/config.exs")
cpus=$(sed -n 's/^ *default_cpus: \([0-9.]*\),.*/\1/p' "$repo/config/config.exs")
image=${IDEJO_IMAGE:-ghcr.io/callisto-rpg/idejo:$version}
idle=${IDLE_SECONDS:-300}
readings=${READINGS:-10}
limit_kib=$((200 * 1000 * 1000 / 1024)) # 200 MB
n="nf02-$$"

cleanup() { docker rm -f "$n-app" "$n-db" >/dev/null 2>&1 || true; docker network rm "$n" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Hub NF-02: $image, POOL_SIZE 5, ${memory_mb} MB and $cpus CPU, idle ${idle}s, $readings readings"
docker network create "$n" >/dev/null
docker run -d --name "$n-db" --network "$n" -e POSTGRES_PASSWORD=pw postgres:18-alpine >/dev/null
until docker exec "$n-db" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
sleep 2
docker exec "$n-db" psql -U postgres -qc "CREATE ROLE forum LOGIN PASSWORD 'pw'" -c "CREATE DATABASE forum OWNER forum"

env=(-e "DATABASE_URL=ecto://forum:pw@$n-db/forum" -e "SECRET_KEY_BASE=$(openssl rand -hex 48)"
  -e PHX_HOST=nf02.idejo.test -e PHX_SERVER=true -e PORT=4000 -e POOL_SIZE=5
  -e IDEJO_UPLOADS_DIR=/data/uploads -e IDEJO_BACKUP_DIR=/data/backups)
docker run -d --name "$n-app" --network "$n" --memory "${memory_mb}m" --cpus "$cpus" "${env[@]}" "$image" \
  sh -c "/app/bin/migrate && /app/bin/server" >/dev/null

# As Caddy sends them: idejo redirects plain http to https unless a trusted proxy (a private
# address, as here) says the visit came over https.
get() {
  docker run --rm --network "$n" curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' \
    -H "Host: nf02.idejo.test" -H "X-Forwarded-Proto: https" "http://$n-app:4000$1"
}
for _ in $(seq 1 90); do [ "$(get /health)" = 200 ] && break; sleep 2; done
[ "$(get /health)" = 200 ] || { docker logs --tail 30 "$n-app"; echo "the forum never answered /health"; exit 1; }
docker exec "$n-app" /app/bin/idejo-admin setup --name "Idle Club" --owner-email owner@nf02.test >/dev/null

# What a visitor loads once (idejo NF-12's list).
for path in / /users/sign-in /users/sign-up /help /rules "/search?q=hello" /privacy \
  /manifest.webmanifest /theme.css /emoji-index.json /sitemap.xml /robots.txt; do
  code=$(get "$path")
  case "$code" in 2*) ;; *) echo "warm-up: $path answered $code"; exit 1 ;; esac
done
echo "warmed: 12 pages, each 2xx"

echo "idle for ${idle}s"
sleep "$idle"

kib() { # "63.11MiB / 384MiB" → KiB
  awk '{v=$1; u=$1; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v);
        f=(u=="GiB")?1048576:(u=="MiB")?1024:(u=="KiB")?1:1/1024; printf "%d\n", v*f}'
}
max=0
for r in $(seq 1 "$readings"); do
  use=$(docker stats --no-stream --format '{{.MemUsage}}' "$n-app")
  k=$(echo "$use" | kib)
  echo "  reading $r: ${use% /*}"
  [ "$k" -gt "$max" ] && max=$k
  [ "$r" -lt "$readings" ] && sleep 30
done

echo "highest: $((max / 1024)) MiB ($((max * 1024 / 1000000)) MB); limit 200 MB"
[ "$max" -lt "$limit_kib" ] || { echo "Hub NF-02: FAILED"; exit 1; }
echo "Hub NF-02: passed"
