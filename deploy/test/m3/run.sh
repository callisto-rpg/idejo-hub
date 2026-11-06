#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Hub milestone 3 exit check (Implementation Prompt, Part B): one person signs up once,
# joins two forums, holds different roles on each, is banned on one and still active on the
# other, then deletes their identity and is removed from both following each forum's rules.
#
# Needs Docker. Run from the repository root:  deploy/test/m3/run.sh
# IDEJO_BASE_IMAGE: an Idejo image with the AC-09 consent and `leave`/`delete-account`
# commands (default ghcr.io/callisto-rpg/idejo:0.2.0). It removes everything it made, pass
# or fail, and exits non-zero on any failure.
#
# How: the real bundle (deploy/docker-compose.yml: Hub, Zitadel, its login screen, Caddy
# with its local CA) plus Mailpit for email. The forums run that Idejo image with Caddy's
# root added to its CA list (a local registry serves it). A browser (browser/check.mjs)
# does everything the person does, on the real pages: the Hub's sign-up, Zitadel's invite
# and sign-in screens, each forum's consent, the Hub's member page. The roles and the ban
# are given on each forum by its own owner (`bin/idejo rpc`), as a forum's staff would.
# Step 6b also checks Hub NF-05: with the Hub stopped, forums and sessions keep working.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
project=idejo-hub-m3
work=$(mktemp -d)
registry=$project-registry
browser=$project-browser
base_image=${IDEJO_BASE_IMAGE:-ghcr.io/callisto-rpg/idejo:0.2.0}
email=mia@idejo.test
password="Mia-$(openssl rand -hex 8)-Pass9!"

compose() { docker compose -p "$project" -f "$root/deploy/docker-compose.yml" -f "$work/override.yml" --env-file "$work/.env" "$@"; }
step() { printf '\n== %s\n' "$*"; }
ok() { echo "  ok  $*"; }
# `rpc` also prints the VM's own warnings: the result is the line starting "=>" (each
# IO.write below becomes a function printing it so).
hub_rpc() { compose exec -T hub bin/idejo_hub rpc "$(rpc_code "$1")" 2>/dev/null | sed -n 's/^=>//p' | tail -n 1; }
forum_rpc() { docker exec "idejo-forum-$1" /app/bin/idejo rpc "$(rpc_code "$2")" 2>/dev/null | sed -n 's/^=>//p' | tail -n 1; }
rpc_code() { printf '%s' "${1//IO.write(/(fn v -> IO.puts(\"=>\" <> to_string(v)) end).(}"; }

cleanup() {
  status=$?
  set +e
  if [ "$status" != 0 ]; then
    echo; echo "== Failed: the last log lines"
    compose logs --no-color --tail 40 hub zitadel 2>/dev/null | grep -v -e ESOCK -e sctp
    for f in alpha bravo; do docker logs --tail 20 "idejo-forum-$f" 2>&1 | sed "s/^/$f | /"; done
    [ -d "$work/out" ] && cp -r "$work/out" "${M3_KEEP:-/tmp}/m3-out-$$" 2>/dev/null && echo "browser output kept in ${M3_KEEP:-/tmp}/m3-out-$$"
  fi
  docker rm -f "$browser" "$registry" >/dev/null 2>&1
  docker volume rm "$project-npm" >/dev/null 2>&1
  for c in $(docker ps -aq --filter "name=^idejo-forum-"); do docker rm -f "$c" >/dev/null; done
  for v in $(docker volume ls -q --filter "name=^idejo-forum-"); do docker volume rm "$v" >/dev/null; done
  compose down -v >/dev/null 2>&1
  docker rmi localhost:5000/idejo:0.2.0 >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

step "1. The Hub's bundle, with Caddy's local CA and Mailpit for email"
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
IDEJO_DEFAULT_VERSION=0.2.0
IDEJO_ID_DOMAIN=id.idejo.test
ZITADEL_MASTERKEY=$(openssl rand -hex 16)
ZITADEL_DB_PASSWORD=$(openssl rand -hex 24)
ZITADEL_ADMIN_PASSWORD=Id-$(openssl rand -hex 12)-Z9
HUB_SMTP_HOST=mailpit
HUB_SMTP_PORT=1025
HUB_SMTP_SECURITY=none
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
  mailpit:
    image: axllent/mailpit:v1.27.0
    environment: {MP_SMTP_AUTH_ACCEPT_ANY: "true", MP_SMTP_AUTH_ALLOW_INSECURE: "true"}
YML
compose up -d --build --wait >/dev/null
echo "  running: $(compose ps --format '{{.Service}}' | tr '\n' ' ')"

step "2. Idejo for the forums, trusting Caddy's local CA, in a local registry"
docker run -d --name "$registry" -p 127.0.0.1:5000:5000 registry:2.8.3 >/dev/null
for _ in $(seq 1 30); do
  compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$work/root.crt" >/dev/null 2>&1 && break
  # The root is made with the first certificate: ask for one.
  compose exec -T caddy wget -q -O /dev/null --no-check-certificate https://id.idejo.test/ 2>/dev/null || true
  sleep 2
done
[ -s "$work/root.crt" ] || { echo "no Caddy root"; exit 1; }
mkdir -p "$work/image" && cp "$work/root.crt" "$work/image/"
cat >"$work/image/Dockerfile" <<DOCKERFILE
FROM $base_image
USER root
COPY root.crt /tmp/caddy-root.crt
RUN cat /tmp/caddy-root.crt >> /etc/ssl/certs/ca-certificates.crt
USER nobody
DOCKERFILE
docker build -q -t localhost:5000/idejo:0.2.0 "$work/image" >/dev/null
docker push -q localhost:5000/idejo:0.2.0 >/dev/null
ok "localhost:5000/idejo:0.2.0 from $base_image"

step "3. Zitadel set up by the Hub (its sign-up off, passkeys and 2FA, SMTP, the member page's client)"
for _ in $(seq 1 60); do
  ready=$(hub_rpc 'IO.write(match?({:ok, _}, IdejoHub.Identity.Members.account_client()))' || true)
  [ "$ready" = "true" ] && break
  sleep 3
done
[ "$ready" = "true" ] || { echo "the Hub never registered its member page at Zitadel"; exit 1; }
ok "the member page's client is registered"

step "4. Two forums, alpha and bravo, each an OpenID Connect client"
for f in alpha bravo; do
  hub_rpc "{:ok, _} = IdejoHub.Forums.create_forum(%{\"subdomain\" => \"$f\", \"display_name\" => \"Club $f\", \"owner_email\" => \"owner-$f@idejo.test\"}, \"m3\")" >/dev/null
done
for f in alpha bravo; do
  for _ in $(seq 1 90); do
    s=$(hub_rpc "IO.write(IdejoHub.Forums.get_by_subdomain(\"$f\").status)" || true)
    [ "$s" = "running" ] || [ "$s" = "failed" ] && break
    sleep 3
  done
  [ "$s" = "running" ] || { echo "$f: $s ($(hub_rpc "IO.write(IdejoHub.Forums.get_by_subdomain(\"$f\").error || \"\")"))"; exit 1; }
  issuer=$(docker exec "idejo-forum-$f" printenv IDEJO_OIDC_ISSUER)
  ok "$f running, signing in through $issuer"
done

browse() {
  local caddy_ip
  caddy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${project}_default\").IPAddress}}" "$project-caddy-1")
  mkdir -p "$work/out" && chmod 777 "$work/out"
  docker rm -f "$browser" >/dev/null 2>&1 || true
  docker run --rm --name "$browser" --network "${project}_default" \
    --add-host "id.idejo.test:$caddy_ip" --add-host "alpha.idejo.test:$caddy_ip" --add-host "bravo.idejo.test:$caddy_ip" \
    -e PHASE="$1" -e EMAIL="$email" -e PASSWORD="$password" -e MAILPIT=http://mailpit:8025 \
    -v "$here/browser:/w:ro" -v "$work/out:/out" -v "$project-npm:/npm" \
    mcr.microsoft.com/playwright:v1.49.1-noble \
    sh -c 'cd /npm && ( [ -d node_modules/playwright ] || (npm init -y >/dev/null &&
             npm install --no-audit --no-fund --silent playwright@1.49.1) ) &&
           cp /w/check.mjs /npm/ && node check.mjs'
  [ -f "$work/out/$1.done" ] || { echo "the browser's $1 phase did not finish"; exit 1; }
}

step "5. In a browser: sign up once on the Hub, then join both forums"
browse join

step "6. Each forum's owner gives the member a role there: moderator on alpha; bravo bans them"
id_alpha=$(forum_rpc alpha "
  member = Idejo.Repo.get_by!(Idejo.Accounts.User, email: \"$email\")
  owner = Idejo.Repo.get_by!(Idejo.Accounts.User, email: \"owner-alpha@idejo.test\")
  {:ok, _} = Idejo.Access.assign_role(owner, member, Idejo.Access.built_in_role!(:moderator))
  IO.write(member.id)")
id_bravo=$(forum_rpc bravo "
  member = Idejo.Repo.get_by!(Idejo.Accounts.User, email: \"$email\")
  owner = Idejo.Repo.get_by!(Idejo.Accounts.User, email: \"owner-bravo@idejo.test\")
  {:ok, _} = Idejo.Accounts.ban_user(owner, member, nil, \"m3 exit check\")
  IO.write(member.id)")
[ -n "$id_alpha" ] && [ -n "$id_bravo" ] || { echo "the member is missing on a forum"; exit 1; }
subject=$(forum_rpc alpha "IO.write(Idejo.Repo.get_by!(Idejo.Accounts.UserIdentity, user_id: \"$id_alpha\").subject)")
[ -n "$subject" ] || { echo "no identity link on alpha"; exit 1; }
printf '{"alpha": "%s", "bravo": "%s"}' "$id_alpha" "$id_bravo" >"$work/out/ids.json"
ok "moderator on alpha ($id_alpha), banned on bravo ($id_bravo)"

step "6b. NF-05: with the Hub stopped, forums stay up and existing sessions keep working"
compose stop hub >/dev/null 2>&1
browse hubdown
compose start hub >/dev/null 2>&1
for _ in $(seq 1 60); do
  [ "$(hub_rpc 'IO.write(:up)' || true)" = "up" ] && break
  sleep 2
done
[ "$(hub_rpc 'IO.write(:up)' || true)" = "up" ] || { echo "the Hub did not come back"; exit 1; }
ok "the Hub is back"

step "7. In a browser: roles differ, the ban holds on bravo only; then the member deletes their Idejo ID"
browse delete

step "8. The deletion reaches both forums, then Zitadel"
for _ in $(seq 1 60); do
  done_at=$(hub_rpc "d = IdejoHub.Identity.Members.deletion(\"$subject\"); IO.write(d && (d.finished_at || d.error) || \"\")" || true)
  [ -n "$done_at" ] && break
  sleep 3
done
case "$done_at" in
  20*) ok "the Hub finished the deletion at $done_at" ;;
  *)
    echo "deletion: ${done_at:-not finished}"
    hub_rpc "IO.write(inspect(Enum.map(IdejoHub.Identity.Members.forums_of(\"$subject\"), &{&1.forum.subdomain, &1.state, &1.error})))"
    exit 1
    ;;
esac
for f in alpha bravo; do
  row=$(forum_rpc "$f" "
    u = Idejo.Repo.get!(Idejo.Accounts.User, \"$(if [ $f = alpha ]; then echo "$id_alpha"; else echo "$id_bravo"; fi)\")
    linked = Idejo.Repo.aggregate(Idejo.Accounts.UserIdentity, :count)
    IO.write(\"#{u.status}|#{u.display_name}|#{u.email == \"$email\"}|#{linked}\")")
  [ "$row" = "deleted|Deleted user|false|0" ] || { echo "$f: $row"; exit 1; }
  ok "$f: the account is anonymised as Idejo's own deletion does (\"Deleted user\", no email, no link)"
done
gone=$(hub_rpc "IO.write(inspect(IdejoHub.Identity.person(\"$subject\")))")
[ "$gone" = "{:error, :not_found}" ] || { echo "Zitadel still has the person: $gone"; exit 1; }
ok "Zitadel no longer has the person"
audit=$(hub_rpc "import Ecto.Query; IO.write(IdejoHub.Repo.all(from a in IdejoHub.Audit.Entry, where: a.actor == \"member:$subject\", select: {a.action, a.outcome}, order_by: a.id) |> Enum.map_join(\" \", fn {a, o} -> a <> \":\" <> o end))")
echo "  audit: $audit"
case "$audit" in *"identity.delete:ok"*) ok "audited as the member, by provider subject" ;; *) echo "no audit entry"; exit 1 ;; esac

step "Hub milestone 3 exit check: passed"
