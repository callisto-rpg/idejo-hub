#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Installs Idejo Hub on a server (HN-08): Debian 13 (trixie), like Idejo. Run it from a clone
# of this repository, as root (with sudo), or as a user who can already run Docker:
#
#   sudo deploy/install.sh
#
# It asks for what it needs, or takes it from options (for scripted installs):
#
#   --hub-domain HOST       the Hub's own address, e.g. hub.example.org
#   --forum-domain DOMAIN   forums are <name>.DOMAIN, e.g. forums.example.org
#   --id-domain HOST        where members sign in (ID-01), default id.<hub domain>;
#                           fixed after the first start (Zitadel keeps it)
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

hub_domain="" forum_domain="" id_domain="" acme_email="" operator="" yes=false

die() { echo "install.sh: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --hub-domain) hub_domain=${2:?}; shift 2 ;;
    --forum-domain) forum_domain=${2:?}; shift 2 ;;
    --id-domain) id_domain=${2:?}; shift 2 ;;
    --acme-email) acme_email=${2:?}; shift 2 ;;
    --operator) operator=${2:?}; shift 2 ;;
    --yes) yes=true; shift ;;
    -h | --help) sed -n '4,22p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

ask() { # ask VAR "question" [DEFAULT]: Enter (or --yes) takes the default, when there is one
  local var=$1 question=$2 default=${3:-} value
  [ -n "${!var}" ] && return
  if $yes; then
    [ -n "$default" ] || die "--${var//_/-} is required with --yes"
    printf -v "$var" '%s' "$default"
    return
  fi
  if [ -n "$default" ]; then
    read -r -p "$question [$default]: " value
    value=${value:-$default}
  else
    read -r -p "$question: " value
  fi
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
if [ -r /etc/os-release ] && . /etc/os-release && [ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ]; then
  echo "Debian 13: supported."
else
  echo "Warning: Idejo Hub is supported on Debian 13 (trixie); this is ${PRETTY_NAME:-unknown}. Going on."
fi

# Tools this script needs; a minimal Debian install may lack some of them.
missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v openssl >/dev/null 2>&1 || missing+=(openssl)
[ -r /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
if [ ${#missing[@]} -gt 0 ]; then
  say "Installing ${missing[*]}"
  [ "$(id -u)" = 0 ] || die "${missing[*]} missing: run this as root (sudo) to install them"
  apt-get update
  apt-get install -y "${missing[@]}"
fi

if ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker (Docker's own packages, with the Compose plugin)"
  [ "$(id -u)" = 0 ] || die "Docker is missing: run this as root (sudo) to install it"
  if ! $yes; then
    read -r -p "Docker with the Compose plugin is missing. Install it now? [y/N] " answer
    [ "$answer" = y ] || [ "$answer" = Y ] || die "Docker is needed: see docs/deploying.md"
  fi
  # Docker's repository for this distribution (debian, or ubuntu on an unsupported system).
  docker_os=debian
  [ "${ID:-}" = ubuntu ] && docker_os=ubuntu
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$docker_os/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$docker_os ${VERSION_CODENAME:-trixie} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker info >/dev/null 2>&1 || die "this user cannot run Docker: run it with sudo"
echo "Docker: $(docker --version)"

say "Settings"
[ -f "$ENV_FILE" ] || { cp deploy/.env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; echo "Created $ENV_FILE."; }

# ID-01: Zitadel keeps its address from its first start, so once deploy/.env has one, a
# different --id-domain is refused rather than silently ignored.
saved_id_domain=$(env_get IDEJO_ID_DOMAIN)
if [ -n "$id_domain" ] && [ -n "$saved_id_domain" ] && [ "$id_domain" != "$saved_id_domain" ]; then
  die "--id-domain $id_domain: $ENV_FILE already has IDEJO_ID_DOMAIN=$saved_id_domain, and Zitadel keeps the address it first started with"
fi

hub_domain=${hub_domain:-$(env_get IDEJO_HUB_DOMAIN)}
forum_domain=${forum_domain:-$(env_get IDEJO_FORUM_DOMAIN)}
id_domain=${id_domain:-$saved_id_domain}
acme_email=${acme_email:-$(env_get ACME_EMAIL)}
ask hub_domain "The Hub's own address (e.g. hub.example.org)"
ask forum_domain "The domain forums are subdomains of (e.g. forums.example.org)"
check_host "--hub-domain" "$hub_domain"
ask id_domain "Where members sign in (cannot be changed later)" "id.$hub_domain"
ask acme_email "Email for Let's Encrypt notices"
check_host "--forum-domain" "$forum_domain"
check_host "--id-domain" "$id_domain"
check_email "--acme-email" "$acme_email"
[ "$id_domain" != "$hub_domain" ] || die "--id-domain must differ from --hub-domain ($hub_domain)"

# A host that is one label under the forum domain looks like a forum to the wildcard:
# that label must never become a forum's name (FL-03).
for host in "$hub_domain" "$id_domain"; do
  label=${host%."$forum_domain"}
  if [ "$label" != "$host" ] && [[ $label != *.* ]]; then
    echo "$host is under the forum domain: no forum can be named \"$label\"."
  fi
done

env_fill IDEJO_HUB_DOMAIN "$hub_domain"
env_fill IDEJO_FORUM_DOMAIN "$forum_domain"
env_fill ACME_EMAIL "$acme_email"
env_fill SECRET_KEY_BASE "$(openssl rand -base64 48 | tr -d '\n')"
env_fill HUB_SECRETS_KEY "$(openssl rand -base64 32 | tr -d '\n')"
env_fill POSTGRES_PASSWORD "$(openssl rand -hex 24)"
env_fill HUB_DB_PASSWORD "$(openssl rand -hex 24)"
# ID-01: Zitadel, at IDEJO_ID_DOMAIN. The master key is exactly 32 characters and never
# changes; the admin password meets Zitadel's policy (upper, lower, digit, symbol).
env_fill IDEJO_ID_DOMAIN "$id_domain"
env_fill ZITADEL_MASTERKEY "$(openssl rand -hex 16)"
env_fill ZITADEL_DB_PASSWORD "$(openssl rand -hex 24)"
env_fill ZITADEL_ADMIN_PASSWORD "Id-$(openssl rand -hex 12)-Z9"
env_fill DOCKER_GID "$(stat -c %g /var/run/docker.sock)"
chmod 600 "$ENV_FILE"
echo "Settings are in $ENV_FILE (readable by root only)."

# HN-01: one wildcard record for the forums, one for the Hub; never a change per forum.
say "Checking DNS"
probe="dns-check-$RANDOM"
hub_ip=$(getent ahostsv4 "$hub_domain" | awk 'NR==1 {print $1}' || true)
id_ip=$(getent ahostsv4 "$id_domain" | awk 'NR==1 {print $1}' || true)
wild_ip=$(getent ahostsv4 "$probe.$forum_domain" | awk 'NR==1 {print $1}' || true)
echo "$hub_domain -> ${hub_ip:-nothing}"
echo "$id_domain -> ${id_ip:-nothing}"
echo "*.$forum_domain (tried $probe.$forum_domain) -> ${wild_ip:-nothing}"
if [ -z "$hub_ip" ] || [ -z "$id_ip" ] || [ -z "$wild_ip" ]; then
  echo "Warning: add these DNS records, pointing to this server, before forums can get certificates:"
  # The wildcard already covers a host one label under the forum domain.
  for host in "$hub_domain" "$id_domain"; do
    label=${host%."$forum_domain"}
    if [ "$label" = "$host" ] || [[ $label == *.* ]]; then
      printf '    %-28s A (and AAAA)\n' "$host"
    fi
  done
  printf '    %-28s A (and AAAA)\n' "*.$forum_domain"
fi

say "Starting Idejo Hub"
# ID-01: an install from before Zitadel has a database without its role: add it (new volumes
# get it from postgres-init/04-zitadel.sh).
"${COMPOSE[@]}" up -d --wait db
if [ -z "$("${COMPOSE[@]}" exec -T db psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'zitadel'")" ]; then
  echo "Adding Zitadel's database role."
  "${COMPOSE[@]}" exec -T -e ZITADEL_DB_PASSWORD="$(env_get ZITADEL_DB_PASSWORD)" db \
    sh /docker-entrypoint-initdb.d/04-zitadel.sh
fi
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
  - Members sign in at https://$id_domain (Zitadel). Its console, for identity
    administration: https://$id_domain/ui/console, user "admin", password ZITADEL_ADMIN_PASSWORD
    in $ENV_FILE.
DONE
