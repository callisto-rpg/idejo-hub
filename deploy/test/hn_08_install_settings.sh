#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# HN-08: deploy/install.sh's settings step, run for real in a scratch copy of deploy/ with a
# stand-in `docker` (nothing is started). Checks the sign-in address (--id-domain): its
# default, a host under the forum domain, and that it cannot change once written.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'FAKE'
#!/bin/sh
# Every call succeeds; "psql" answers that Zitadel's role exists.
case "$*" in *psql*) echo 1 ;; *--version*) echo "Docker version (stand-in)" ;; esac
exit 0
FAKE
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

fails=0
check() { # check NAME CONDITION...
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}

fresh() { rm -rf "$work/r"; mkdir -p "$work/r"; cp -r "$repo/deploy" "$work/r/deploy"; rm -f "$work/r/deploy/.env"; }
run() { "$work/r/deploy/install.sh" "$@" >"$work/out" 2>&1; }
env_of() { sed -n "s/^$1=//p" "$work/r/deploy/.env" | tail -n 1; }
base=(--hub-domain hub.example.test --forum-domain forums.example.test --acme-email ops@example.test)

fresh
run --yes "${base[@]}"
check "default sign-in address is id.<hub domain>" test "$(env_of IDEJO_ID_DOMAIN)" = id.hub.example.test

fresh
run --yes --hub-domain hub.example.test --forum-domain example.test --id-domain login.example.test \
  --acme-email ops@example.test
check "--id-domain is written" test "$(env_of IDEJO_ID_DOMAIN)" = login.example.test
check "hosts under the forum domain are named" grep -q 'no forum can be named "login"' "$work/out"
check "the Hub's host too" grep -q 'no forum can be named "hub"' "$work/out"
check "the DNS hint lists the wildcard" grep -qE '^    \*\.example\.test ' "$work/out"
check "and not the hosts it covers" sh -c "! grep -qE '^    (hub|login)\.example\.test ' '$work/out'"

secret=$(env_of HUB_SECRETS_KEY)
if run --yes "${base[@]}" --id-domain other.example.test; then refused=no; else refused=yes; fi
check "a different --id-domain later is refused" test $refused = yes
check "and says why" grep -q 'Zitadel keeps the address' "$work/out"
check "deploy/.env is unchanged" test "$(env_of IDEJO_ID_DOMAIN)" = login.example.test
run --yes "${base[@]}" --id-domain login.example.test
check "the same --id-domain again is fine" test "$(env_of HUB_SECRETS_KEY)" = "$secret"

fresh
if run --yes "${base[@]}" --id-domain hub.example.test; then refused=no; else refused=yes; fi
check "the sign-in address cannot be the Hub's" test $refused = yes

fresh
printf 'hub.example.test\nforums.example.test\n\nops@example.test\n\n' |
  "$work/r/deploy/install.sh" >"$work/out" 2>&1
check "asked: Enter takes the default" test "$(env_of IDEJO_ID_DOMAIN)" = id.hub.example.test

fresh
printf 'hub.example.test\nexample.test\nlogin.example.test\nops@example.test\n\n' |
  "$work/r/deploy/install.sh" >"$work/out" 2>&1
check "asked: a typed address is kept" test "$(env_of IDEJO_ID_DOMAIN)" = login.example.test

if [ $fails != 0 ]; then echo "$fails failed."; exit 1; fi
echo "All passed."
