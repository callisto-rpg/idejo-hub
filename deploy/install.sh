#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Installs Idejo Hub on a server (HN-08): Ubuntu 24.04 LTS, like Idejo. Run it from a clone
# of this repository, as root (with sudo), or as a user who can already run Docker:
#
#   sudo deploy/install.sh
#
# It asks for what it needs, or takes it from options (for scripted installs):
#
#   --hub-domain HOST       the Hub's own address, e.g. hub.example.org
#   --forum-domain DOMAIN   forums are <name>.DOMAIN, e.g. forums.example.org
#   --acme-email EMAIL      for Let's Encrypt notices
#   --operator EMAIL        the first operator's email
#   --yes                   do not ask; install Docker when it is missing
#
# Run it again at any time: deploy/.env is created once and its secrets are never changed;
# only missing values are added. Docs: docs/deploying.md.

set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=deploy/.env
COMPOSE=(docker compose -f deploy/docker-compose.yml --env-file "$ENV_FILE")

hub_domain="" forum_domain="" acme_email="" operator="" yes=false

die() { echo "install.sh: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --hub-domain) hub_domain=${2:?}; shift 2 ;;
    --forum-domain) forum_domain=${2:?}; shift 2 ;;
    --acme-email) acme_email=${2:?}; shift 2 ;;
    --operator) operator=${2:?}; shift 2 ;;
    --yes) yes=true; shift ;;
    -h | --help) sed -n '4,20p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

ask() { # ask VAR "question"
  local var=$1 question=$2 value
  [ -n "${!var}" ] && return
  $yes && die "--${var//_/-} is required with --yes"
  read -r -p "$question: " value
  printf -v "$var" '%s' "$value"
}

# Reads a value from deploy/.env (empty when missing).
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -n 1; }

# Sets a value in deploy/.env only when it is missing or empty: secrets are never replaced.
env_fill() {
  local key=$1 value=$2
  if [ -n "$(env_get "$key")" ]; then return; fi
  if grep -q "^$key=" "$ENV_FILE"; then
    # The value never holds "|" (generated or checked below).
    sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

check_host() { # check_host NAME VALUE
  [[ $2 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
    die "$1 must be a host name in lowercase, like example.org (got: $2)"
}

check_email() { [[ $2 =~ ^[^@[:space:]|]+@[^@[:space:]|]+\.[^@[:space:]|]+$ ]] || die "$1 must be an email address (got: $2)"; }

say "Checking the server"
# shellcheck source=/dev/null
if [ -r /etc/os-release ] && . /etc/os-release && [ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ]; then
  echo "Ubuntu 24.04: supported."
else
  echo "Warning: Idejo Hub is supported on Ubuntu 24.04 LTS; this is ${PRETTY_NAME:-unknown}. Going on."
fi

if ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker (Docker's own packages, with the Compose plugin)"
  [ "$(id -u)" = 0 ] || die "Docker is missing: run this as root (sudo) to install it"
  if ! $yes; then
    read -r -p "Docker with the Compose plugin is missing. Install it now? [y/N] " answer
    [ "$answer" = y ] || [ "$answer" = Y ] || die "Docker is needed: see docs/deploying.md"
  fi
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-noble} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker info >/dev/null 2>&1 || die "this user cannot run Docker: run it with sudo"
echo "Docker: $(docker --version)"

say "Settings"
[ -f "$ENV_FILE" ] || { cp deploy/.env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; echo "Created $ENV_FILE."; }

hub_domain=${hub_domain:-$(env_get IDEJO_HUB_DOMAIN)}
forum_domain=${forum_domain:-$(env_get IDEJO_FORUM_DOMAIN)}
acme_email=${acme_email:-$(env_get ACME_EMAIL)}
ask hub_domain "The Hub's own address (e.g. hub.example.org)"
ask forum_domain "The domain forums are subdomains of (e.g. forums.example.org)"
ask acme_email "Email for Let's Encrypt notices"
check_host "--hub-domain" "$hub_domain"
check_host "--forum-domain" "$forum_domain"
check_email "--acme-email" "$acme_email"

env_fill IDEJO_HUB_DOMAIN "$hub_domain"
env_fill IDEJO_FORUM_DOMAIN "$forum_domain"
env_fill ACME_EMAIL "$acme_email"
env_fill SECRET_KEY_BASE "$(openssl rand -base64 48 | tr -d '\n')"
env_fill HUB_SECRETS_KEY "$(openssl rand -base64 32 | tr -d '\n')"
env_fill POSTGRES_PASSWORD "$(openssl rand -hex 24)"
env_fill HUB_DB_PASSWORD "$(openssl rand -hex 24)"
env_fill DOCKER_GID "$(stat -c %g /var/run/docker.sock)"
chmod 600 "$ENV_FILE"
echo "Settings are in $ENV_FILE (readable by root only)."

# HN-01: one wildcard record for the forums, one for the Hub; never a change per forum.
say "Checking DNS"
probe="dns-check-$RANDOM"
hub_ip=$(getent ahostsv4 "$hub_domain" | awk 'NR==1 {print $1}' || true)
wild_ip=$(getent ahostsv4 "$probe.$forum_domain" | awk 'NR==1 {print $1}' || true)
echo "$hub_domain -> ${hub_ip:-nothing}"
echo "*.$forum_domain (tried $probe.$forum_domain) -> ${wild_ip:-nothing}"
if [ -z "$hub_ip" ] || [ -z "$wild_ip" ]; then
  echo "Warning: add these DNS records, pointing to this server, before forums can get certificates:"
  echo "    $hub_domain        A (and AAAA)"
  echo "    *.$forum_domain    A (and AAAA)"
fi

say "Starting Idejo Hub"
"${COMPOSE[@]}" up -d --build --wait

if [ -z "$operator" ] && ! $yes; then
  read -r -p "First operator's email (empty to skip; add one later with bin/hub-admin): " operator
fi
if [ -n "$operator" ]; then
  say "Creating the operator $operator"
  "${COMPOSE[@]}" exec -T hub bin/hub-admin create-operator "$operator" ||
    echo "Not created (it may exist already)."
fi

say "Done"
cat <<DONE
Idejo Hub is running at https://$hub_domain
  - Sign in with the operator's email and the password shown above; you set up two-factor
    sign-in with an authenticator app the first time.
  - Keep a copy of $ENV_FILE somewhere safe, away from this server. HUB_SECRETS_KEY above all:
    without it the Hub cannot read the forums' secrets.
  - More operators: ${COMPOSE[*]} exec hub bin/hub-admin create-operator EMAIL
DONE
