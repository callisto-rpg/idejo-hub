#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# HN-04: runs the real chain (docker-guard → socket-proxy → Docker) from deploy/ and checks
# that harmless calls pass and dangerous ones are refused. Needs Docker; run from the
# repository root:  guard/test/hn_04_chain.sh
set -euo pipefail

project=idejo-hub-hn04
env_file=$(mktemp)
trap 'docker compose -p $project -f deploy/docker-compose.yml -f guard/test/hn_04_chain.override.yml --env-file "$env_file" down -v >/dev/null 2>&1; rm -f "$env_file"' EXIT

cat > "$env_file" <<ENV
IDEJO_HUB_DOMAIN=hub.idejo.test
ACME_EMAIL=ops@idejo.test
SECRET_KEY_BASE=test
POSTGRES_PASSWORD=test
HUB_DB_PASSWORD=test
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
ENV

docker compose -p $project -f deploy/docker-compose.yml -f guard/test/hn_04_chain.override.yml \
  --env-file "$env_file" up -d --build --wait socket-proxy docker-guard db

g=http://127.0.0.1:23750/v1.44
failures=0

# expect STATUS DESCRIPTION curl-args...
expect() {
  local want=$1 what=$2
  shift 2
  local got
  for _ in $(seq 1 20); do
    got=$(curl -s -o /dev/null -w '%{http_code}' "$@") && [ "$got" != 000 ] && break
    sleep 1
  done
  if [ "$got" = "$want" ]; then echo "ok    $got $what"; else echo "FAIL  $got (want $want) $what"; failures=$((failures + 1)); fi
}

json=(-X POST -H 'content-type: application/json')

limits='"Memory":268435456,"NanoCpus":500000000,"NetworkMode":"idejo-forums"'
label='"Labels":{"org.idejo.hub.forum":"citest"}'
image='"Image":"ghcr.io/callisto-rpg/idejo:0.1.0"'

expect 200 "ping" "$g/_ping"
expect 403 "system info is not on the list" "$g/info"
expect 403 "another container cannot be inspected" "$g/containers/${project}-db-1/json"
expect 403 "privileged container" "${json[@]}" "$g/containers/create?name=idejo-forum-citest" \
  -d "{$image,$label,\"HostConfig\":{\"Privileged\":true,$limits}}"
expect 403 "host root bind-mounted" "${json[@]}" "$g/containers/create?name=idejo-forum-citest" \
  -d "{$image,$label,\"HostConfig\":{\"Binds\":[\"/:/host\"],$limits}}"
expect 403 "host PID namespace" "${json[@]}" "$g/containers/create?name=idejo-forum-citest" \
  -d "{$image,$label,\"HostConfig\":{\"PidMode\":\"host\",$limits}}"
expect 403 "another image" "${json[@]}" "$g/containers/create?name=idejo-forum-citest" \
  -d "{\"Image\":\"alpine:3.20\",$label,\"HostConfig\":{$limits}}"
expect 403 "volume bound to a host path" "${json[@]}" "$g/volumes/create" \
  -d '{"Name":"idejo-forum-citest-x","Labels":{"org.idejo.hub.forum":"citest"},"DriverOpts":{"type":"none","o":"bind","device":"/"}}'
expect 201 "forum volume" "${json[@]}" "$g/volumes/create" \
  -d '{"Name":"idejo-forum-citest-uploads","Labels":{"org.idejo.hub.forum":"citest"}}'
expect 204 "forum volume removed" -X DELETE "$g/volumes/idejo-forum-citest-uploads"

[ "$failures" = 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "HN-04 chain: all checks passed"
