#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Hub milestone 2 exit check (Implementation Prompt, Part B): from the Hub's web interface,
# create four forums, suspend and resume one, back up and restore one, upgrade all four with
# one deliberately failing (it must roll back alone), export one and restore that export on a
# standalone Idejo install, delete one. All within 4 GB.
#
# Needs Docker. Run from the repository root:  deploy/test/m2/run.sh
# It removes everything it made, pass or fail, and exits non-zero on any failure.
#
# How: the real bundle (deploy/docker-compose.yml) with Caddy's local CA; a local registry
# holds Idejo 0.1.0 and an "0.1.1" whose server refuses to start for delta.* (broken/); a
# browser (browser/check.mjs) drives the Hub's pages; then the downloaded export is restored
# on a plain `docker run` Idejo. Memory of the Hub's containers and the forums is sampled
# all along; the peak must stay under 4 GiB.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
project=idejo-hub-m2
work=$(mktemp -d)
registry=$project-registry
browser=$project-browser
standalone=$project-standalone
base_image=${IDEJO_BASE_IMAGE:-ghcr.io/callisto-rpg/idejo:0.1.0}
budget=$((4 * 1024 * 1024 * 1024))

compose() { docker compose -p "$project" -f "$root/deploy/docker-compose.yml" -f "$work/override.yml" --env-file "$work/.env" "$@"; }
step() { printf '\n== %s\n' "$*"; }

cleanup() {
  status=$?
  set +e
  if [ "$status" != 0 ]; then
    echo; echo "== Failed: the Hub's and docker-guard's last log lines"
    compose logs --no-color --tail 60 hub docker-guard 2>/dev/null | grep -v -e ESOCK -e sctp
  fi
  [ -n "${sampler:-}" ] && kill "$sampler" 2>/dev/null
  docker rm -f "$browser" "$registry" "$standalone" "$standalone-db" >/dev/null 2>&1
  for c in $(docker ps -aq --filter "name=^idejo-forum-"); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q --filter "name=^idejo-forum-"); do docker volume rm "$v" >/dev/null; done
  docker volume rm "$standalone-backups" >/dev/null 2>&1
  docker network rm "$standalone" >/dev/null 2>&1
  compose down -v >/dev/null 2>&1
  docker rmi localhost:5000/idejo:0.1.0 localhost:5000/idejo:0.1.1 >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

step "1. Idejo 0.1.0 and a deliberately failing 0.1.1 in a local registry"
docker pull -q "$base_image" >/dev/null
docker run -d --name "$registry" -p 127.0.0.1:5000:5000 registry:2.8.3 >/dev/null
sleep 2
docker tag "$base_image" localhost:5000/idejo:0.1.0
docker push -q localhost:5000/idejo:0.1.0 >/dev/null
docker build -q --build-arg BASE=localhost:5000/idejo:0.1.0 -t localhost:5000/idejo:0.1.1 "$here/broken" >/dev/null
docker push -q localhost:5000/idejo:0.1.1 >/dev/null
echo "  $(curl -s http://127.0.0.1:5000/v2/idejo/tags/list)"

step "2. The Hub's bundle, with Caddy's local CA"
cat >"$work/.env" <<ENV
IDEJO_HUB_DOMAIN=hub.idejo.test
IDEJO_FORUM_DOMAIN=idejo.test
ACME_EMAIL=ops@idejo.test
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
HUB_SECRETS_KEY=$(openssl rand -base64 32 | tr -d '\n')
POSTGRES_PASSWORD=$(openssl rand -hex 24)
HUB_DB_PASSWORD=$(openssl rand -hex 24)
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
IDEJO_FORUM_IMAGE=localhost:5000/idejo
IDEJO_DEFAULT_VERSION=0.1.0
IDEJO_HUB_UPGRADE_HEALTH_SECONDS=90
IDEJO_ID_DOMAIN=id.idejo.test
ZITADEL_MASTERKEY=$(openssl rand -hex 16)
ZITADEL_DB_PASSWORD=$(openssl rand -hex 24)
ZITADEL_ADMIN_PASSWORD=Id-$(openssl rand -hex 12)-Z9
ENV
# shellcheck disable=SC2016 # Caddy placeholders, not shell variables.
sed 's/^\temail {\$ACME_EMAIL}$/\temail {$ACME_EMAIL}\n\tlocal_certs/' "$root/deploy/Caddyfile" >"$work/Caddyfile"
cat >"$work/override.yml" <<YML
services:
  caddy:
    ports: !override []
    volumes:
      - $work/Caddyfile:/etc/caddy/Caddyfile:ro
      - forum-state:/srv/forum-state:ro
      - $root/deploy/maintenance:/srv/maintenance:ro
YML
compose up -d --build --wait >/dev/null
echo "  running: $(compose ps --format '{{.Service}}' | tr '\n' ' ')"

# Peak memory of the Hub's containers and the forums (not the registry or the browser).
(
  peak=0
  while true; do
    total=$(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' |
      awk -v p="$project" '$1 ~ "^"p"-(hub|db|caddy|docker-guard|socket-proxy|zitadel)" || $1 ~ /^idejo-forum-/ {
        split($2, a, /[A-Za-z]+/); v = a[1]; u = $2; gsub(/[0-9.]/, "", u)
        if (u == "GiB") v *= 1073741824; else if (u == "MiB") v *= 1048576; else if (u == "KiB") v *= 1024
        s += v } END { printf "%d", s }')
    [ "${total:-0}" -gt "$peak" ] && peak=$total && echo "$peak" >"$work/peak"
    sleep 5
  done
) &
sampler=$!

step "3. An operator"
operator_out=$(compose exec -T hub bin/hub-admin create-operator ops@idejo.test 2>/dev/null)
password=$(echo "$operator_out" | sed -n 's/^    \([^ ]\{20,\}\)$/\1/p' | head -1)
[ -n "$password" ] || { echo "no operator password"; exit 1; }
echo "  ops@idejo.test created"

step "4. In a browser, through the Hub's pages"
caddy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${project}_default\").IPAddress}}" "$project-caddy-1")
hosts=()
for h in hub alpha bravo charlie delta; do hosts+=(--add-host "$h.idejo.test:$caddy_ip"); done
mkdir -p "$work/out" && chmod 777 "$work/out"
docker run --rm --name "$browser" --network "${project}_default" "${hosts[@]}" \
  -e OPERATOR_EMAIL=ops@idejo.test -e "OPERATOR_PASSWORD=$password" \
  -v "$here/browser:/w:ro" -v "$work/out:/out" \
  mcr.microsoft.com/playwright:v1.49.1-noble \
  sh -c 'mkdir -p /tmp/m2 && cp /w/check.mjs /tmp/m2/ && cd /tmp/m2 &&
         npm init -y >/dev/null && npm install --no-audit --no-fund --silent playwright@1.49.1 &&
         node check.mjs'
[ -f "$work/out/done" ] || { echo "the browser check did not finish"; exit 1; }

step "5. charlie's export, restored on a standalone Idejo (no Hub)"
docker network create "$standalone" >/dev/null
docker volume create "$standalone-backups" >/dev/null
docker run -d --name "$standalone-db" --network "$standalone" -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=idejo postgres:18-alpine >/dev/null
file=$(tar -tf "$work/out/export.tar" >/dev/null 2>&1 && echo export.tar)
[ -n "$file" ] || { echo "the download is not a tar archive"; exit 1; }
name=idejo-$(date -u +%Y%m%d-%H%M%S).tar
docker run --rm -v "$standalone-backups:/b" -v "$work/out:/src:ro" alpine:3.20 \
  sh -c "cp /src/export.tar /b/$name && chown -R 65534:65534 /b"
env_sa=(-e "DATABASE_URL=ecto://postgres:pw@$standalone-db/idejo" -e "SECRET_KEY_BASE=$(openssl rand -hex 48)"
  -e PHX_HOST=standalone.idejo.test -e IDEJO_BACKUP_DIR=/data/backups -e IDEJO_UPLOADS_DIR=/data/uploads -e PHX_SERVER=true)
sleep 4
docker run --rm --network "$standalone" "${env_sa[@]}" "$base_image" /app/bin/migrate >/dev/null 2>&1
docker run --rm --network "$standalone" "${env_sa[@]}" -v "$standalone-backups:/data/backups" "$base_image" \
  /app/bin/idejo-admin restore "$name" --yes 2>/dev/null | grep -i restored
docker run -d --name "$standalone" --network "$standalone" "${env_sa[@]}" -v "$standalone-backups:/data/backups" \
  "$base_image" sh -c "/app/bin/migrate && /app/bin/server" >/dev/null
sleep 20
# `health` exits non-zero when any check fails: the push keys cannot be read on an install
# with another SECRET_KEY_BASE (Idejo encrypts them with it), which is expected here.
health=$(docker exec "$standalone" /app/bin/idejo-admin health 2>/dev/null || true)
server_name=$(docker exec "$standalone-db" psql -U postgres -d idejo -tAc "select value from settings where key='server_name'")
echo "$health" | grep -E "database|migrations|owner|push keys" | sed 's/^/  /'
for check in "database" "migrations" "owner"; do
  echo "$health" | grep -qE "^ok +$check" || { echo "standalone: $check is not ok"; exit 1; }
done
echo "  note: push keys need the forum's SECRET_KEY_BASE, which a standalone install does not have"
[ "$server_name" = "Club charlie" ] || [ "$server_name" = '"Club charlie"' ] ||
  { echo "standalone server name: $server_name"; exit 1; }
echo "  ok  the standalone install is \"Club charlie\", owner set up"

step "6. Memory"
kill "$sampler" 2>/dev/null; sampler=""
peak=$(cat "$work/peak" 2>/dev/null || echo 0)
echo "  peak of the Hub's containers and forums: $((peak / 1048576)) MiB (budget $((budget / 1048576)) MiB)"
[ "$peak" -lt "$budget" ] || { echo "over 4 GiB"; exit 1; }

step "Hub milestone 2 exit check: passed"
