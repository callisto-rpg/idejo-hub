<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# CLAUDE.md — Idejo Hub

Read this file before every task. Update it in the same pull request whenever a change
affects architecture, conventions, commands or milestone status (DV-01).

`AGENTS.md` holds the generic Phoenix and LiveView usage rules from the generator; this file
wins wherever the two differ.

## What the Hub is

A separate control app that runs several independent Idejo forums on one server, each on its
own subdomain, each an **unmodified** Idejo container with its own database, uploads and
secrets. The Hub creates, suspends, backs up, restores, upgrades and deletes them from the
outside, and (milestone 3) gives them one shared sign-in identity over OpenID Connect.
Each forum is administered by its own owner inside the forum, as if standalone, and can leave
the Hub at any time as a normal Idejo install with all its data.

## Specifications — the source of truth

- `Idejo Hub — Spec Sheet.md` — what the Hub must do. IDs: BI, FL, ID, HN, OP, SC, HA, NF, LB.
  Write Hub NF IDs as **"Hub NF-xx"** wherever they could be confused with Idejo's NF IDs.
- `Idejo Hub — Implementation Prompt.md` — the steward's decisions, ground rules and the order
  of work (Part B is for this repository; Part A is for the `idejo` repository).
- Idejo's `CLAUDE.md` → **Running under Idejo Hub** — the only interface the Hub may use to
  drive a forum (see The one rule).

Requirement IDs are stable. Never renumber or invent them. If a task is not covered by an ID,
stop and ask; do not invent behaviour. The specs are written by the steward, not by Claude; do
not edit them unless asked (LI-08).

## The one rule

**The Hub talks to Idejo only through the contract in Idejo's `CLAUDE.md` → Running under
Idejo Hub; never read or write a forum's database.** That contract is:

- environment variables (Idejo AD-13): `PHX_HOST`, `DATABASE_URL`, `SECRET_KEY_BASE`,
  `IDEJO_UPLOADS_DIR`, `IDEJO_BACKUP_DIR`, `IDEJO_SOURCE_URL`, `IDEJO_SMTP_*`,
  `IDEJO_TRUSTED_PROXIES`, `IDEJO_OIDC_*`, `IDEJO_LOCAL_ACCOUNTS`;
- `bin/idejo-admin` (Idejo AD-09, AD-14): `setup`, `backup`, `restore FILE --yes`, `health`,
  with exit codes;
- `GET /health` (Idejo AD-15): 200 or 503 with `{status, version, checks}`;
- OpenID Connect (Idejo AC-09), with the Hub as provider;
- Docker: the official Idejo image, one container per forum.

If the Hub needs something the contract does not offer (for example deleting a member for
ID-06), **stop and ask**; the fix is a new documented interface in Idejo, never a direct
database query, a patched image or a Hub-only code path inside Idejo. The Hub must keep
working across Idejo minor versions without code changes, and each Hub release states the
Idejo versions it supports (Hub NF-06).

## Stack

Same as Idejo, so skills, tooling and visual language are shared (HA): Elixir + Phoenix
LiveView, PostgreSQL (the Hub's own database, on the PostgreSQL server shared with the forums),
Oban for scheduled and lifecycle jobs, Caddy in front of everything (on-demand TLS, HN-02),
shipped as Docker Compose with an install script (HN-08). Elixir and Erlang versions are the
same as Idejo's, pinned in `.tool-versions` (DV-04).

As built by Foundations:

- Phoenix 1.8.15, LiveView 1.2, Bandit, Tailwind 4 + daisyUI (vendored by the generator, no
  Node), no mailer yet (alerts, OP, add Swoosh when needed).
- Req (Apache-2.0) for HTTP to docker-guard. `docker_guard` is a path dependency in tests
  only, so the Hub's tests check that what the Hub sends is what the guard allows.
- Oban 2.24, queues `lifecycle` (FL) and `operations` (OP), Pruner plugin; jobs only run when a
  test runs them (`testing: :manual`). Migration `priv/repo/migrations/*_add_oban_jobs.exs`.
- `IdejoHubWeb.Plugs.ContentSecurityPolicy`: strict CSP with per-request script and style
  nonces (as Idejo); inline `<script>`/`<style>` must carry `@script_csp_nonce` /
  `@style_csp_nonce`.
- Production refuses to start without `PHX_HOST`, `DATABASE_URL` and `SECRET_KEY_BASE`
  (`config/runtime.exs`); an empty `POOL_SIZE` means the default, 10.
- Release `idejo_hub` (`mix release`) ships `LICENSE`, `NOTICE` and `LICENSES/` at its root
  (`copy_licence/1` in `mix.exs`); `rel/overlays/bin/{server,migrate}` from
  `mix phx.gen.release`. `Dockerfile` pins the Elixir/Erlang/Debian base images.
- Development PostgreSQL (root `docker-compose.yml`) is published on **5433**, so it runs
  beside Idejo's development database on 5432; `config/dev.exs`, `config/test.exs` and CI use
  5433.

## Architecture

```
lib/idejo_hub/        business logic (contexts) — no web code
lib/idejo_hub_web/    web layer — operator interface (LiveView), Caddy "ask" endpoint, identity pages
  plugs/              ContentSecurityPolicy
  hosting/            Docker adapter (Docker.Engine, Docker.Fake), ForumContainer (HN-04),
                      Postgres: one database and role per forum (HN-05)
guard/                docker-guard (HN-04): separate mix project and release; Policy decides,
                      Router forwards to socket-proxy's Unix socket; guard/Dockerfile
deploy/               production bundle (HN-08): docker-compose.yml, Caddyfile, .env.example,
                      postgres-init/ (creates the Hub's CREATEDB/CREATEROLE role, never superuser),
                      socket-proxy and docker-guard (HN-04)
docker-compose.yml    development PostgreSQL only (port 5433)
```

The context folders below are created by the first PR that needs them.

| Prefix | Context folder | Notes |
| --- | --- | --- |
| FL | `lib/idejo_hub/forums/` | Forum records and lifecycle; each action an Oban job with clear states. `Forums.Subdomain` (FL-03): the subdomain is also the slug every name derives from |
| HN | `lib/idejo_hub/hosting/` | Docker adapter (with a fake for tests), PostgreSQL provisioning, Caddy routes, `ask` endpoint |
| OP | `lib/idejo_hub/operations/` | Backups, restore, upgrades and rollback, health polling, alerts |
| ID | `lib/idejo_hub/identity/` | OpenID Connect provider (milestone 3; provider choice still open) |
| SC | `lib/idejo_hub/audit/`, `lib/idejo_hub/secrets.ex` | Audit log, encrypted per-forum secrets |
| HA | `lib/idejo_hub_web/` | Operator screens; Hub CLI later (HA-08) |
| LB | — | Source link per forum (`IDEJO_SOURCE_URL`), branding rules |

Design points (Implementation Prompt, Part B, milestone 2):

- **Docker** behind one adapter module, through `docker-guard` and the socket proxy (steward
  decision 2026-11-03, below). The Hub never mounts the Docker socket. Forum names are fixed
  so the guard can check them: container `idejo-forum-<slug>`, volumes
  `idejo-forum-<slug>-{uploads,backups}`, label `org.idejo.hub.forum=<slug>`, network
  `idejo-forums`, image `ghcr.io/callisto-rpg/idejo:X.Y.Z`. A new Docker call or create field
  needs a rule in `DockerGuard.Policy` (with a refused example in its test) and, for a new
  path, the socket-proxy allowlist in `deploy/docker-compose.yml`; both are DV-06 reviews.
- **PostgreSQL**: the Hub's role has `CREATEDB` and `CREATEROLE`, never superuser. One
  database and one login role per forum, both named `forum_<slug>` (hyphens → underscores),
  that role able to reach only its own database (HN-05): `CONNECT` revoked from `PUBLIC`
  everywhere, and `pg_hba.conf` `sameuser` for network connections
  (`deploy/postgres-init/02-forum-isolation.sh`), so a role opens only the database of its
  own name. That includes the Hub, which cannot open a forum's database at all. DDL runs on a
  short Postgrex connection of its own (not the Repo pool); a new database or service needs
  a role of the same name.
- **Secrets** (SC-04): `IdejoHub.Secrets` generates each forum's `SECRET_KEY_BASE` and DB
  password and encrypts them (AES-256-GCM, `:crypto`, key `HUB_SECRETS_KEY`) before they reach
  the Hub database. Every value is bound to a context, `"forum:<slug>:<field>"`, so it cannot
  be moved to another forum or field. Store only `encrypt/2` output, never plain secrets; the
  Hub refuses to boot without a valid key. Dev and test have fixed keys in their config.
- **Caddy** (HN-02, `deploy/Caddyfile`): on-demand TLS for every host; `ask`
  (`GET /internal/caddy/ask`, `CaddyController`, `Forums.certificate_allowed?/1`) says yes
  only for existing, non-deleted forums and the Hub's own host. No per-forum routes: the
  wildcard site sends `<subdomain>.IDEJO_FORUM_DOMAIN` to `idejo-forum-<subdomain>:4000`
  (so nothing to re-apply on boot), with `strict_sni_host` so the Host must match the
  certificate. 502/503/504 go to `GET /internal/forum-unavailable` (being set up, paused,
  unavailable, or 404). `/internal/*` is refused from outside by Caddy and excluded from the
  Hub's `force_ssl` (Caddy calls it over plain http).
- **Every lifecycle step cleans up fully on failure**, and every action writes an audit entry
  from the start (SC-07 shows them in milestone 4): `IdejoHub.Audit.record/5` (actor, action
  such as `forum.create`, outcome `requested`/`ok`/`failed`, forum, details without secrets
  or command output); `audit_entries` is append-only (trigger).
- **Forums** (FL-01): `Forums.create_forum/2` stores the forum as `creating` with its
  encrypted `SECRET_KEY_BASE` and queues `Forums.CreateWorker` (queue `lifecycle`, one
  attempt), whose steps (`database`, `container`, `starting`, `health`, `setup`) show in
  `forums.step`; it ends `running`, or `failed` with a short `error` after removing only what
  it made. `Hosting.Health` polls `http://idejo-forum-<slug>:4000/health` on the forum
  network. The output of `idejo-admin setup` (it may hold the owner's link) is never logged
  or stored. Settings: `IDEJO_FORUM_DOMAIN` (required in production), `IDEJO_DEFAULT_VERSION`.
- Per-forum memory and CPU limits on every container (SC-05).

## Conventions

<!-- REUSE-IgnoreStart -->
- **SPDX header** on every source file (LI-01): `SPDX-FileCopyrightText: 2026 Mariano Pictet
  and contributors`, `SPDX-License-Identifier: AGPL-3.0-only` (steward decision, 2026-11-02;
  may change after legal review, LB-02). `reuse lint` must pass. Files that cannot carry a
  header are listed in `REUSE.toml`, as are the generator's vendored MIT files.
<!-- REUSE-IgnoreEnd -->
- Never hard-code a domain. Development and tests use `*.idejo.test`; the production domain is
  still open (LB-05).
- Contexts expose plain functions returning `{:ok, _} | {:error, _}`; LiveViews stay thin.
- No new dependency without a licence check: MIT, BSD, Apache-2.0 or similar only (LI-06).
  Name the licence in the PR description.
- No secret in logs, audit entries or error messages.

## Workflow

- One requirement per pull request (DV-05), ID in the PR title; tests named and tagged after
  the ID (DV-02).
- Commits made with Claude Code end with the trailer `Assisted-by: Claude Code` (LI-08).
- CLA (LI-05): `.github/workflows/cla.yml` asks every contributor to sign Idejo's CLA (same
  steward); signatures go to the `cla-signatures` branch.
- CI (`.github/workflows/ci.yml`): REUSE lint; format, compile warnings, credo `--strict`,
  sobelow, `deps.audit`, `hex.audit`, unused deps; Dialyzer (dev env); tests against
  PostgreSQL 18; the same checks for `guard/`; the Compose bundle is validated, the image
  built, and `guard/test/hn_04_chain.sh` run against the runner's Docker.
- A person reviews every PR. Identity, secrets, Docker access and anything touching sign-in
  get an extra careful human review (DV-06) — flag them in the PR description. Every OIDC
  change is in that group.
- Stop at the end of each milestone, report its exit check, and wait for the steward.

## Commands

```sh
mise install                 # Elixir and Erlang from .tool-versions
docker compose up -d         # development PostgreSQL on 127.0.0.1:5433
mix setup                    # deps, database, assets
mix phx.server               # http://localhost:4000 (LiveDashboard at /dev/dashboard)
mix test                     # all tests
mix test --only req:FL-01    # one requirement's tests
mix precommit                # compile warnings, format, credo, sobelow, audits, tests, dialyzer
reuse lint                   # SPDX headers (LI-01)
(cd guard && mix precommit)  # docker-guard's own checks and tests (HN-04)
guard/test/hn_04_chain.sh    # real chain against local Docker: harmless calls pass, dangerous refused
```

Production bundle (HN-08; the install script comes with milestone 2):

```sh
cp deploy/.env.example deploy/.env    # then fill it in
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
```

## Steward decisions

- 2026-11-02 — Account model: shared Idejo identity (spec §5); the Hub is the OpenID Connect
  provider, each forum a client.
- 2026-11-02 — Licence: AGPL-3.0-only headers for now, same steward and CLA as Idejo.
- 2026-11-02 — OIDC provider (built in or existing open-source beside it): **open.** Before
  milestone 3, write a one-page proposal (licence, memory, maintenance, passkeys) and wait.
- 2026-11-03 — Docker access (HN-04): option B of `docs/proposals/hn-04-docker-access.md`.
  Only wollomatic/socket-proxy (MIT, pinned by digest) mounts the socket, read-only, and it
  allows only the listed method/path pairs. `docker-guard` (a second release from this
  repository) checks every create/exec body in front of it. The Hub reaches Docker only
  through `IdejoHub.Hosting.Docker` and never mounts the socket.
- Open: production domain (LB-05); read-only backup and health view for forum owners.

## Milestones (Hub spec §12)

- [x] **1 — Base Idejo ready** — Idejo milestone M6, built in the `idejo` repository. Done
  2026-11-03: Idejo `v0.1.0` published as `ghcr.io/callisto-rpg/idejo:0.1.0` (and `:0.1`).
- [x] **Foundations** (may start now, one PR) — Phoenix LiveView app, this file completed,
  SPDX headers, NOTICE, CLA check, CI (format, credo, dialyzer, sobelow, tests, deps audit,
  reuse lint), `docker-compose.yml` with Hub app, PostgreSQL and Caddy (HN-08).
- [ ] **2 — Hub alpha** — FL-01 to FL-06, OP-01 to OP-05, HA-01 to HA-05, HN-01 to HN-05, HN-07,
  SC-01, SC-04 to SC-06, SC-08, SC-09; separate accounts per forum.
- [ ] 3 — Shared identity — ID-01 to ID-09, forums switched to Idejo's OIDC client.
- [ ] 4 — Hub 1.0 — OP-02, OP-06 to OP-10, SC-02, SC-03, SC-07, SC-10, HA-06 to HA-09, HN-06,
  Hub NF-01 to NF-07, LB-01, LB-04, operator docs.
- Later, do not start: FL-07 to FL-10, HN-03.

Current milestone: **2 — Hub alpha**. Exit checks for each milestone are
in the Implementation Prompt, Part B.
