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
  `IDEJO_TRUSTED_PROXIES`, `IDEJO_OIDC_*`, `IDEJO_LOCAL_ACCOUNTS`, `POOL_SIZE` (NF-01),
  and since Idejo 0.2.5 `IDEJO_COMMUNITY_URL`, `IDEJO_COMMUNITY_DIRECTORY_URL` (its community
  menu, below);
- `bin/idejo-admin` (Idejo AD-09, AD-14): `setup`, `backup`, `restore FILE --yes`, `health`,
  `stats` (JSON counts and sizes; Idejo after 0.1.0), `rotate-push-keys --yes`, with exit codes;
- `GET /health` (Idejo AD-15): 200 or 503 with `{status, version, checks}`;
- OpenID Connect (Idejo AC-09), with the Hub as provider;
- Docker: the official Idejo image, one container per forum.

If the Hub needs something the contract does not offer (for example deleting a member for
ID-06), **stop and ask**; the fix is a new documented interface in Idejo, never a direct
database query, a patched image or a Hub-only code path inside Idejo. The Hub must keep
working across Idejo minor versions without code changes, and each Hub release states the
Idejo versions it supports (Hub NF-06).

Supported Idejo versions (Hub NF-06): **0.2.9**, the default for new forums
(`IDEJO_DEFAULT_VERSION`); 0.2.0 was the first with the shared-identity commands and OIDC
client (AC-09), 0.2.2 the first whose stylesheet is checked (Idejo AD-11, for SC-03), 0.2.4
the first whose image runs in interactive release mode (Idejo NF-12; Hub NF-02, below), 0.2.5
the first with the community menu (below), 0.2.6 the first whose sign-in shows "No Idejo ID
yet? Create one" (`IDEJO_OIDC_SIGN_UP_URL`, below). Forums on 0.2.5 run without that link,
on 0.2.4 also without the menu.
Forums on 0.2.2 and 0.2.3 run as before but idle over 200 MB (208 MiB warmed); 0.2.0 and 0.2.1 accept any
custom CSS (their content security policy still refuses outside loads); forums on 0.1.0
still run, back up and upgrade, but have no `stats` and no shared sign-in. Upgrade them to
0.2.9 (the first with `/logo`, the forum's logo for the directory's cards; before it, a card
shows no logo).

**Forums directory and community menu** (steward decisions 2026-11-06; `IdejoHub.Community`):
`https://forums.<IDEJO_FORUM_DOMAIN>/` (`DirectoryController`, `Plugs.DirectoryHost`, a
named Caddy site before the forum wildcard; `ask` allows it) lists every running forum the
operator has not hidden (`forums.listed`, "Hide from the directory" / "Show in the
directory" on its page, audited `forum.unlisted` / `forum.listed`); `forums` is a reserved
subdomain (FL-03), so no forum can take it. Every forum with a client gets Idejo's
`IDEJO_COMMUNITY_DIRECTORY_URL` (that page) and `IDEJO_COMMUNITY_URL`
(`http://hub:4000/internal/community`, on the forum network; Caddy refuses `/internal/*`
from outside): `CommunityController` answers `GET ?subject=` with HTTP Basic, the asking
forum's own client id and secret, only about a person who joined that forum, with the other
running forums they joined (`identity_joins`). Forums ask it over plain http: like every `/internal`
route it is left out of production's `force_ssl` (`config/prod.exs`; a redirect there made
every menu silently empty; `internal_http_test.exs` checks the list). With the Hub down the menu lists nothing and
the forum runs (Hub NF-05). The directory shows one card per forum with its logo (Idejo
0.2.9's `https://<host>/logo`; the content security policy's `img-src` allows
`https://*.<forum domain>`), and past ten listed forums a search (name or host, any
case, `%` and `_` literal) and pages of ten (`Community.directory_page/2`, hosted and
outside forums together). Tests: `community_directory_test.exs`.

**Outside forums** (steward decisions 2026-11-06; `Identity.OutsideForums`,
`RegistryController`, `OutsideForumsLive`; extra review: DV-06): an Idejo server hosted
elsewhere signs in with this Hub's Idejo ID. JSON under `/account/api` on the sign-in host
(the `:api` pipeline: no session, so no CSRF token; `sc_02_csrf_test.exs` checks it):
`POST registrations` (host, name; ten an hour per address) answers a `registration` key and
a `proof`; the forum serves the proof at `https://<host>/.well-known/idejo-id-registration`
(`Identity.Proof`: public addresses only, the checked one asked, https, no redirects) and
`POST registrations/verify` makes its client (`Identity.create_client/1`), or renews a known
host's secret, and answers issuer, client id and secret once (only hashes stored). Asking
again changes nothing until proven. Hosts under the forum domain and the Hub's own are
refused. With its client credentials (Basic) the forum reads and sets its directory listing
(`GET`/`PUT listing`: `none`, `requested`, `approved`, `refused`): an operator approves or
refuses at `/outside-forums` (a new name asks again; a refused one asks again only after
leaving), and Remove deletes its client. Approved ones join the directory; the page's
`img-src` names their hosts (`:csp_img_hosts`, the CSP header written at send). Sign-up
leads back to a registered one. Audited `identity.outside_forum.register`, `.listing`,
`.approve`, `.refuse`, `.remove`. Tests: `outside_forums_test.exs`.

**Hub NF-02** (an idle forum under 200 MB; steward decision 2026-11-06): Idejo's image runs
`RELEASE_MODE=interactive` from 0.2.4 (modules load when first used), the Hub's own
interface untouched (the one rule). `deploy/test/nf_02_idle_memory.sh` runs one forum as the
Hub does (default version, `POOL_SIZE` 5, the default memory and CPU limits, read from the
config), sets it up, loads 12 pages (2xx, through `X-Forwarded-Proto: https` as Caddy sends
it), idles 5 minutes and fails if a reading reaches 200 MB; nightly
(`.github/workflows/nf-02-idle-memory.yml`). Measured on 2026-11-06, warmed and idle: 80 MiB
(84 MB) with interactive mode; 0.2.3, in embedded mode, 208 MiB (218 MB): over.

**SC-03** (custom CSS sanitised, third-party scripts forbidden) is Idejo's: a forum's
stylesheet is its own setting, which the Hub never reads or writes. Idejo 0.2.2 checks it
before saving (no `@import`, no `url()` but local paths and `data:`, nothing that ran script;
`Idejo.Settings.Stylesheet`), and every Idejo page's content security policy refuses scripts
and loads from other hosts (Idejo SP-04, SP-05). The Hub's part: new forums start on 0.2.2 or
later (`test/idejo_hub/sc_03_custom_css_test.exs`).

**NF-01** (1 to 30 forums per server; steward decisions 2026-11-06): the shared PostgreSQL's
connections are the limit (measured: an idle forum holds its pool and Oban's listener, 11 at
Idejo's default; Zitadel 14; the Hub 11). `ForumContainer.spec/1` gives every forum
`POOL_SIZE=5` (6 connections; a fixed variable, so the caller cannot raise it; Idejo documents
`POOL_SIZE` in its AD-13 table), and the bundle's `db` runs with `max_connections=320`: 30
forums, the Hub, Zitadel, 10 for backups and one-off jobs, and room for about 10 more forums.
Past `Forums.supported_forums/0` (30) forums not deleted (`Forums.hosted_count/0`), the
create, import and restore-to-new forms show `CoreComponents.forum_limit_notice/1`
(`#forum-limit`, `role="status"`) and still allow it. A change to a pool, to Zitadel or to the
Hub's connections updates the figures in `docker-compose.yml`,
`test/idejo_hub_web/live/nf_01_supported_size_test.exs` and `deploy/test/nf_01_connections.sh`
(which holds them all on the bundle's PostgreSQL, in CI's Compose job).

**Hub NF-05** (the Hub being down does not take forums down): nothing on a forum's way
depends on the Hub. Caddy sends forum hosts straight to their containers and reads suspensions
from files; it has no `depends_on` the Hub (it starts and runs whatever the Hub's state;
until the Hub answers, only new certificates wait for `ask`); the Hub appears in a forum's
site only once the forum itself fails (its 502–504 page). Forums sign in through Zitadel
(`IDEJO_OIDC_ISSUER`, never the Hub) and keep their own sessions; only the member page
(`/account`) and sign-up are the Hub's. Checked from the bundle
(`test/idejo_hub/hosting/nf_05_hub_down_test.exs`) and live in `deploy/test/m3/run.sh`
step 6b: the Hub stopped, a member's session, the forum and Zitadel still answer.

**HN-06** (the Hub and the identity provider in their own containers, with their own
database): the `hub` and `zitadel` services are containers of their own (the Hub built here,
Zitadel its pinned image; no shared namespaces; Zitadel only on the default network, no
Docker access), each with its own role and database on the shared PostgreSQL server
(`idejo_hub`, `zitadel`: `postgres-init/01-hub-role.sh`, `04-zitadel.sh`), neither
superuser, each closed to `PUBLIC` and, over the network, opening only the database named
after it (`sameuser`). The one crossing is sanctioned: the Hub holds Zitadel's database
password to back it up (OP-10, steward decision 2026-11-04). Checked from the bundle's files
(`test/idejo_hub/hosting/hn_06_own_containers_test.exs`) and live against the bundle's own
PostgreSQL (`deploy/test/hn_06_databases.sh`, in CI's Compose job).

## Stack

Same as Idejo, so skills, tooling and visual language are shared (HA): Elixir + Phoenix
LiveView, PostgreSQL (the Hub's own database, on the PostgreSQL server shared with the forums;
HN-06, below),
Oban for scheduled and lifecycle jobs, Caddy in front of everything (on-demand TLS, HN-02),
shipped as Docker Compose with an install script (HN-08). Elixir and Erlang versions are the
same as Idejo's, pinned in `.tool-versions` (DV-04).

As built by Foundations:

- Phoenix 1.8.15, LiveView 1.2, Bandit, Tailwind 4 + daisyUI (vendored by the generator, no
  Node). Swoosh (MIT) with gen_smtp (BSD-2-Clause; ranch ISC, idna MIT) for the Hub's own
  email, OP-08's alerts (`IdejoHub.Mailer`, added 2026-11-06).
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
| ID | `lib/idejo_hub/identity/` | Zitadel beside the Hub (milestone 3): forum clients, member pages, deletion |
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
  certificate. When the Hub's or the sign-in host is one label under the forum domain, that
  label is never a forum name (`Subdomain.own_labels/0`, FL-03), so the wildcard cannot claim
  it. 502/503/504 go to `GET /internal/forum-unavailable` (being set up, paused,
  unavailable, or 404). `/internal/*` is refused from outside by Caddy and excluded from the
  Hub's `force_ssl` (Caddy calls it over plain http).
- **Every lifecycle step cleans up fully on failure**, and every action writes an audit entry
  from the start: `IdejoHub.Audit.record/5` (actor, action such as `forum.create`, outcome
  `requested`/`ok`/`failed`, forum, details without secrets or command output);
  `audit_entries` is append-only (trigger). SC-07 shows them: the operator at `/audit`
  (`AuditLive`, `Audit.list/1`: newest first, 50 a page by id, filters `forum`, `action`
  prefix, `outcome`, `actor`, in the address; linked in the header and from each forum's
  page), and a forum's owner on their Idejo ID page (`/account/forums/<slug>/log`,
  `AccountController.log/2`, `Audit.recent_for_forum/2`: newest 200). The Hub knows an owner
  only by `forums.owner_email`: the log shows to a member whose Idejo ID email, **verified**
  by the provider (`Identity.person/1`'s `email_verified`, Zitadel's `isVerified`), is that
  address, any case (`Forums.owned_by/1`); anyone else gets 404. For owners actions read in
  words (`AccountHTML.what/1`), a member is "A member" (never `member:<subject>`; identity
  entries' `subject` detail dropped), and storage keys are left out.
- **Forums** (FL-01): `Forums.create_forum/2` stores the forum as `creating` with its
  encrypted `SECRET_KEY_BASE` and queues `Forums.CreateWorker` (queue `lifecycle`, one
  attempt), whose steps (`database`, `container`, `starting`, `health`, `setup`) show in
  `forums.step`; it ends `running`, or `failed` with a short `error` after removing only what
  it made. `Hosting.Health` polls `http://idejo-forum-<slug>:4000/health` on the forum
  network. The output of `idejo-admin setup` (it may hold the owner's link) is never logged
  or stored. Settings: `IDEJO_FORUM_DOMAIN` (required in production), `IDEJO_DEFAULT_VERSION`.
- **Suspend and resume** (FL-04): `Forums.suspend_forum/2` / `resume_forum/2` (one action
  at a time: row lock, `step` set) queue `SuspendWorker` / `ResumeWorker`. Suspend marks the
  host (`Hosting.Maintenance`: an empty file per host in the `forum-state` volume, which
  Caddy reads) then stops the container; Caddy serves the static
  `deploy/maintenance/index.html` (503) for marked hosts, even with the Hub down. Resume
  starts it, waits for `/health`, then unmarks. Database, volumes and container are kept.
  The marks are rebuilt from the database at boot (`Maintenance.sync/0`). Jobs end through
  `Forums.finish_action/4` / `fail_action/4`; errors read from `Forums.Errors.describe/1`.
- **Export** (FL-06): `Forums.export_forum/2` (running or suspended) queues `ExportWorker`
  (queue `operations`): a one-off container `idejo-forum-<slug>-export`
  (`ForumContainer.run_one_off/3`: the forum's spec, `idejo-admin` command, restart `no`, no
  alias; `Forums.container_params/1` gives the environment) runs `idejo-admin backup`; the
  file named in its output (only `/data/backups/idejo-YYYYMMDD-HHMMSS.tar`) is copied out
  (`Docker.copy_from/3`: the archive must hold exactly that one regular file) into
  `<exports dir>/<subdomain>/` (`/data/exports`, the `exports` volume), with a
  `forum_exports` row (kind `export` or `final`, size, SHA-256; no foreign key, kept after
  deletion). Restores on a standalone install with `idejo-admin restore FILE --yes` (on a
  migrated database).
- **Delete** (FL-05): `Forums.delete_forum/3` (running, suspended or failed; `immediate:
  true` needs `confirm:` the subdomain) queues `DeleteWorker`: a final export
  (`ExportWorker.export/2`, kind `final`; nothing is deleted without it), the maintenance
  mark, the container stopped, `deleting` with `purge_at` (`deletion_grace_days`, 30, or
  now), and `PurgeWorker` scheduled then (snoozes if early; does nothing unless still
  `deleting`): container, volumes, database, role, mark and stored secrets removed,
  `deleted`. Exports stay. `cancel_deletion/2` → `suspended`, purge job cancelled. A failed
  forum is just marked `deleted`. Deleted rows stay; their subdomain is free again (partial
  unique index), and `get_by_subdomain/1` / `for_host/1` ignore them.
- **Scheduled backups** (OP-01, `lib/idejo_hub/operations/`): Oban cron
  (`IDEJO_HUB_BACKUP_CRON`, default `0 2 * * *` UTC) runs `BackupScheduler`, which calls
  `Forums.backup_forum/2` for every running forum (skipping busy ones, logged); each
  `BackupWorker` execs `idejo-admin backup` inside the running container and
  `Forums.Archives.collect/4` copies the named file into the Hub's store as kind `backup`;
  `Archives.prune/3` keeps the newest `IDEJO_HUB_BACKUPS_KEPT` (14) per forum. Idejo's own
  `backup` keeps 7 in the forum volume, so the 14 live in the Hub's `exports` volume.
  Audited `forum.backup` (actor `schedule`). Exports, final exports and backups all share
  `forum_exports` and `Archives`.
- **Hub backups** (OP-10, `Operations.HubBackup`, `HubBackupWorker`; extra review: DV-06):
  `BackupScheduler` also queues one backup of the Hub's own database (`hub`) and Zitadel's
  (`zitadel`, only when `ZITADEL_DB_PASSWORD` is set): `pg_dump --format=custom`, each as that
  database's own role (the Hub's from its Repo config; Zitadel's password is passed to the
  Hub: steward decision 2026-11-04), written as `.part` and renamed, into
  `<exports dir>/_hub/<kind>-YYYYMMDD-HHMMSS.dump`, with a `hub_backups` row (size,
  SHA-256); the newest `IDEJO_HUB_BACKUPS_KEPT` of each kind kept. One at a time (Oban
  unique on the worker); also "Back up the Hub now" on `/server` (`Operations.backup_hub/1`).
  Audited `hub.backup` (no forum; `failed` names the database and pg_dump's exit code,
  never its output). The image has `postgresql-client-18` from PGDG (Debian's is older than
  the server). Tests use `test/support/bin/pg_dump`.
- **Off-server copies** (OP-02, `Operations.Offsite`, `OffsiteWorker`; extra review: DV-06;
  steward decision 2026-11-04): on while `IDEJO_HUB_S3_BUCKET` is set (the Hub refuses to
  boot with a bucket and no valid `IDEJO_HUB_BACKUP_AGE_RECIPIENT`). After each scheduled
  forum backup (`BackupWorker`) and each Hub dump (`HubBackupWorker`), `OffsiteWorker.queue/1`
  (queue `operations`, three attempts) runs `age --encrypt --recipient` into a `.age.part`
  next to the file (always removed), uploads it with Req's `aws_sigv4` (path-style; one PUT
  up to 16 MiB, else multipart, a part at a time; aborted on failure) as
  `<prefix>forums/<subdomain>/<file>.age` or `<prefix>hub/<file>.age`, sets `offsite_key`
  and `offsite_at` on the row, then keeps the newest `IDEJO_HUB_BACKUPS_KEPT` under that
  forum's or that Hub database's key prefix (list v2, delete). Audited
  `forum.backup.offsite` / `hub.backup.offsite` (`ok` with key, size, pruned; `failed`
  after the last attempt). S3 settings are environment only (`deploy/.env`), shown on
  Settings without the access keys. Exports, final exports and pre-upgrade backups are not
  copied. The image has `age` (BSD-3-Clause, Debian). Tests: `test/support/bin/age`,
  `IdejoHub.S3Fake` (`:offsite_req_options`).
- **Restore** (OP-03, `Operations.RestoreWorker`): `Forums.restore_forum/4` (running or
  suspended, from the forum's own archives of any kind) marks the host, stops the
  container, puts the file in its backups volume (`Docker.copy_to/3`), runs `idejo-admin
  restore FILE --yes` in a one-off `-restore` container, starts it, waits for `/health`,
  unmarks. A failure before the restore puts the forum back; after it, the forum stays
  stopped and marked as `suspended`. `Forums.restore_to_new/3` creates a forum (FL-01 via
  `create_forum/3`'s `job_args`, no headless setup, behind the page) and restores into it.
  Idejo's secret settings are encrypted with `SECRET_KEY_BASE`: a deleted source's key moves
  with its data; a live source's is never shared (SC-04), so the new forum gets its own and
  a one-off `rotate-push-keys --yes`, and a panel SMTP password must be entered again.
- **Upgrade** (OP-04, `Operations.UpgradeWorker`): `Forums.upgrade_forum/3` (running, a newer
  exact version only): pull the image while the forum still runs (Hub NF-04; a failed pull
  changes nothing), mark the host, `idejo-admin backup` in the container kept as kind
  `upgrade` (never pruned; a failure so far removes the mark), then
  `ForumContainer.recreate/1` (stop, remove, create on the new version; volumes never
  touched) with `IDEJO_SOURCE_URL` following `forums.idejo_version` (LB-03), start, `/health`
  within `IDEJO_HUB_UPGRADE_HEALTH_SECONDS` (300). Failure: recreate on the old version,
  restore the pre-upgrade backup in a one-off, start, health → `running` on the old version,
  audited `rolled_back: true`; if that fails too, stopped and marked as `suspended`.
  **Hub NF-04**: the `forum.upgrade` entry's `downtime_seconds` (mark to unmark) and
  `forum.create`'s `seconds` (request to running) are asserted on real containers by
  `deploy/test/m2/run.sh` step 4b (upgrades under 60 s; measured 52 s each on 0.1.0 →
  0.1.1 with half a CPU) and `deploy/test/m3/run.sh` step 4 (creation under 120 s;
  measured 23–45 s).
- **Upgrade all** (OP-05, `Operations.upgrade_all/2`, `Operations.BulkUpgradeWorker`): the
  running forums on an older version, by subdomain (others listed as skipped), one run at a
  time. Each step starts the next forum's OP-04 upgrade with `bulk:` (the run) in its
  arguments; `UpgradeWorker` calls `BulkUpgradeWorker.continue/3` when it ends: success
  queues the next step, failure (rolled back or not) stops the run. Audited
  `forums.upgrade_all` (no forum): `requested` with the list, then `ok` with `done`, or
  `failed` with `done`, `failed`, `not_attempted`. A busy forum is waited for (snooze).
- **Pin** (OP-06, `Forums.set_pinned/3`, `forums.pinned`): a pinned forum is left out of
  upgrade all (listed as `pinned` in the run's `requested` entry and the flash), and skipped
  by `BulkUpgradeWorker` when pinned after the run was asked for; a single upgrade still
  works. "Pin to X.Y.Z" / "Unpin" on the forum's page (`#pin`), a "pinned" badge by the
  version in the list. Audited `forum.pin` / `forum.unpin` with the version.
- **New releases** (OP-09, `Operations.Releases`, `ReleaseCheckWorker`, cron daily 06:17
  UTC): reads Idejo's tags from `IDEJO_HUB_RELEASES_URL` (default GitHub's tag list for the
  Idejo repository: no credentials, nothing about the Hub sent; set empty to turn it off),
  keeps the newest stable `vX.Y.Z` in the `settings` table (key `idejo_latest_release`, not
  one of Settings' keys); when newer than `IDEJO_DEFAULT_VERSION`, the forum list and
  `/server` show `CoreComponents.release_notice/1` (`#release-notice`) linking to
  `IDEJO_HUB_CHANGELOG_URL` (`{from}`, `{to}`; default GitHub's compare view: Idejo publishes
  no release notes yet). A failed check keeps what was known. Tests stub it
  (`:releases_req_options`).
- **Operator sign-in** (SC-08, `IdejoHub.Operators`, `IdejoHubWeb.OperatorAuth`,
  `SessionController`; extra review: DV-06): operators are made only by `bin/hub-admin
  create-operator EMAIL` (`IdejoHub.Release`; random password shown once; no sign-up page) and
  sign in with the password (Argon2id at Idejo's cost), then a TOTP code (`nimble_totp`;
  secret encrypted, context `operator:<id>:totp`; set up at the first sign-in and confirmed
  by a code; a code's 30 s step is kept so it works once; the previous step is accepted).
  Between the two, the session holds only `pending_operator_id` for five minutes. Five
  failures in a row lock the account for 15 minutes. Sessions: a random token in the
  session cookie (`IdejoHubWeb.SessionCookie`: encrypted, HttpOnly, SameSite=Strict,
  host-only, Secure outside dev and tests, then named `__Host-idejo_hub` so no subdomain can
  set it: SC-02), its SHA-256 in `operator_tokens`, 12 hours; sign-in renews the session.
  **SC-02**: every forum is same-site to the Hub, so SameSite stops nothing from a forum's
  pages: the CSRF token does. Every route that is not GET goes through `:browser`
  (`:protect_from_forgery`); GET never changes anything but the audit log (archive
  downloads); LiveView's socket needs the session's token (`connect_info: [session: …]`) and
  the Hub's own origin (default `check_origin`, never set off outside development). A new
  route is checked by `test/idejo_hub_web/sc_02_csrf_test.exs`. Forums: Idejo SP-05, SP-10.
  `bin/hub-admin reset-two-factor EMAIL` clears the setup and ends the sessions. Every
  operator page goes through the router's `:operator` pipeline; pass
  `current_operator={@current_operator}` to `Layouts.app` (email and Sign out). Audited
  `operator.create`, `operator.sign_in` (ok/failed with the factor, never a password or
  code), `operator.two_factor_reset`.
- **Operator roles** (HA-07, `operators.role`, `Operators.owner?/1`, `set_role/3`,
  `remove_operator/2`; extra review: DV-06): `owner` or `operator`. Owners also manage
  operator accounts at `/operators` (`OperatorsLive`, `live_session :owner`,
  `on_mount: {OperatorAuth, :require_owner}`; linked in the header for owners only): add one
  (one-time password shown once), change a role, remove one (its sessions end with it). The
  last owner stays an owner, nobody removes their own account. Everything else is open to
  both roles (a further split needs a steward decision). `create_operator/3` without a role
  makes the first account an owner and later ones operators; `bin/hub-admin create-operator
  EMAIL --role owner|operator` sets it. Operators made before roles became owners
  (migration). Audited `operator.create` (with `role`, by the command line or the owner),
  `operator.role`, `operator.remove`.
- **Operator screens** (HA): LiveViews in `lib/idejo_hub_web/live/`, in the router's
  `live_session :operator` (`on_mount: {OperatorAuth, :require_operator}`), rendered in
  `<Layouts.app current_operator={@current_operator}>` (`wide` for tables). They follow
  `Forums.subscribe/0` (`{:forum_changed, forum}`, broadcast by `update_state/2` and
  `create_forum/3`). HA-01 forum list at `/` (`ForumListLive`): filter `?status=`, sort
  `?sort=`; members and disk use (database + uploads) come from each forum's `idejo-admin stats`
  (Idejo AD-09), kept on the forum by `Operations.StatsWorker` every 15 minutes (cron);
  without them (Idejo before `stats`) members show "—" and the size is the latest backup's.
  OP-07 health overview in the same list: `Operations.HealthWorker` (cron every minute,
  Oban queue `health` of its own) checks each running forum not busy with an action:
  `Hosting.Health.check/1` and `Docker.stats/1` (memory without the page cache, and the
  container's limit; docker-guard allows `GET /containers/<forum>/stats`), kept on the forum
  (`health` `ok`/`down`, `health_at`, `down_since`: the first check that found it down,
  cleared when it answers, for OP-08; `memory_bytes`, `memory_limit_bytes`). Forums not
  running keep no health. Columns Health ("up", "down since HH:MM UTC") and Memory ("used of
  limit", amber past 90%), sortable (`?sort=health`: down first). Disk use stays with the
  15-minute `stats` (an `idejo-admin` run per forum each minute would cost a release boot).
  OP-08 alerts (`Operations.Alerts`), emailed to Settings' alert address through
  `IdejoHub.Mailer` (Swoosh SMTP over `Settings.shared_smtp/0`, read at each send, as Idejo's
  port rule: `tls` on 465, else `starttls`; peer verified; from `noreply@<Hub host>`,
  "Idejo Hub"): after each health check, a forum `down_since` 5 minutes or more
  (`check_forums/1`) and the store's disk (`check_disk/1`: above 85%, cleared under 80%) open
  an `alerts` row (unique `key`: `forum_down:<slug>`, `disk`) and send one email, its end
  (answering again; under 80%) one more; a forum leaving `running` drops its row silently. A
  failed forum backup (`BackupWorker`), Hub backup (`HubBackupWorker`) or off-server copy's
  last attempt (`OffsiteWorker`) sends one each (`backup_failed/3`). Every email is audited
  `alert.email` (`ok`, or `failed` with the reason: no alert address, no SMTP, the server's
  answer). Tests: `Swoosh.Adapters.Test`, and `config :idejo_hub, Alerts, disk: :unavailable`
  so no test reads the machine's disk. HA-02 create form at `/forums/new` (`ForumNewLive`): the subdomain
  checked while typing (FL-03 rules and free), created as the signed-in operator's email.
  HA-03 forum page at `/forums/:id` (`ForumShowLive`): health (`start_async`), actions
  through `Forums` as the operator (suspend, resume, back up, export, upgrade, restore here
  or to new, delete with grace or now with the subdomain typed, cancel, owner's link once),
  archives, audit log. Downloads: `GET /forums/:forum_id/archives/:id` (`ArchiveController`,
  audited `forum.archive.download`, only that forum's archives).
  HA-04 server page at `/server` (`ServerLive`, `Operations.Server.snapshot/0`, every 10 s):
  load and memory from `/proc`, disk from `df` on the exports volume, PostgreSQL sizes from
  `hub_database_sizes()` (`deploy/postgres-init/03-database-sizes.sh`: superuser-owned,
  names and sizes only) or the databases the role may connect to, forum containers through
  docker-guard. A reading that fails shows as unavailable.
  HA-05 settings at `/settings` (`SettingsLive`, `IdejoHub.Settings`, table `settings`, JSON
  values, secrets encrypted with context `setting:<key>`): SMTP shared by forums
  (`Settings.shared_smtp/0`: set here, it replaces `HUB_SMTP_*` whole; reaches a forum when
  its container is made), alert email (for OP-08), extra reserved subdomains (refused by
  `Forum.create_changeset/2`). Forum domain and backup storage are shown, not edited.
  Audited `settings.update` (keys only). Changed settings reach forums when their containers
  are made again: `Forums.recreate_forum/2` (`RecreateWorker`: same version, volumes kept;
  running ones marked, restarted and health-checked, suspended ones left stopped) and
  `recreate_all/1` ("Apply to all forums now" in Settings; "Recreate" on a forum's page).
- **Import** (FL-07, `Forums.import_forum/4`, `Forums.Import`, `ForumImportLive` at
  `/forums/import`; steward decision 2026-11-05): a standalone `idejo-admin backup` archive,
  uploaded by the operator (LiveView upload, at most `IDEJO_HUB_IMPORT_MAX_MB`, 4096), is
  checked like Idejo's restore does (`Import.check/1`: only `manifest.json`,
  `database.dump`, `uploads/<name>`; manifest format 1 with its migration; nothing extracted
  but the manifest), then made a forum like OP-03's restore to new: `create_forum/3`'s
  `attach:` stores it in the same transaction (`Import.store/2`: `<exports dir>/<subdomain>/
  idejo-YYYYMMDD-HHMMSS.tar`, never over a kept file; `forum_exports` kind `import`, never
  pruned; audited `forum.import` with file, size, SHA-256 and which key, never the key), no
  headless setup, then `RestoreWorker`. Local accounts always on (ID-07: the members'
  passwords come with it). The standalone's `SECRET_KEY_BASE`, when given (64+ characters),
  moves with the data; else a new one and `rotate-push-keys`. The form checks its fields
  and key before taking the file (`Forums.check_available/1`, `valid_import_key?/1`).
- **Standalone key** (FL-06): `Forums.reveal_secret_key_base/2` hands the operator a forum's
  `SECRET_KEY_BASE` for a standalone restore of its export (Idejo encrypts its secret
  settings with it), audited `forum.secret_key_base.reveal` each time, kept by the Hub.
  The forum list also starts OP-05 (`#upgrade-all`, `Operations.upgrade_all/2`).
- **Command line** (HA-08, `IdejoHub.CLI`, `Release.cli/2`): `bin/hub-admin forums`,
  `create`, `backup`, `upgrade`, `suspend`, `resume` run inside the running Hub (`rpc`; the
  script checks it runs), each argument Base64-encoded into the code it sends (never
  interpolated). Each action starts through `Forums` as actor `command line`, then waits
  for its first `ok`/`failed` audit entry after it began (every action writes one; 30
  minutes at most), printing the outcome; exit 0 done, 1 failed or refused (with the
  reason), 2 no such forum, 64 usage (`exit({:shutdown, code})`, never halting the Hub). A
  new action for scripts joins `CLI`, `Release.run_cli/2` and the script's usage.
- **Isolation checks** (`test/idejo_hub/sc_isolation_test.exs`): SC-01 host-only cookies,
  SC-05 limits on every container spec, SC-06 the only `idejo-admin` commands the Hub runs
  are `setup`, `backup`, `restore`, `rotate-push-keys` (a new one updates that test, after
  review), SC-09 every operator route needs sign-in and forums get no Hub secret and no way
  to docker-guard (read from `deploy/docker-compose.yml`).
- **Identity provider** (ID-01; steward decision 2026-11-03): Zitadel v4 (pinned by digest)
  and its separate login screen (`zitadel-login`) in the bundle, at `IDEJO_ID_DOMAIN`
  (`id.<hub domain>`): Caddy sends `/ui/v2/login*` to the login screen, `/account*` and the
  files members' pages load (`/assets/css/*`, `/assets/js/*`, `/images/*`, `/fonts/*`; never
  Zitadel's own `/assets/v1/*`) to the Hub, and the rest to Zitadel over h2c; the `ask` endpoint allows that host. Its own role and database on the
  shared PostgreSQL (`postgres-init/04-zitadel.sh`; the installer adds them to an existing
  volume), `start-from-init` with its own role as "admin" (never the superuser; its first
  connection to its own database, as `sameuser` allows). The first start makes org "Idejo",
  an `admin` (password `ZITADEL_ADMIN_PASSWORD`), a machine user `idejo-hub` (org owner)
  and the login client, and writes their tokens to the `zitadel-tokens` volume (all three
  containers run as nobody; `zitadel-tokens-init` hands the volume over). The Hub reads its
  token from `ZITADEL_TOKEN_FILE` (`IdejoHub.Identity` config).
- **Forum clients** (ID-01, ID-07; `IdejoHub.Identity`, adapter `Identity.Zitadel` over its
  management API v1 with the Hub's token, `Identity.Fake` in tests, off when unset): each
  forum is an OIDC web app in project "Idejo forums" (code flow, client secret Basic,
  `https://<host>/users/oidc/callback`, user info in the ID token), registered by the
  `identity` step of `CreateWorker` (removed again if a later step fails, and at purge);
  `Forums.ensure_identity_client/1` connects older forums on recreate,
  `rotate_identity/2` rotates the secret and recreates. `container_params/1` gives
  `IDEJO_OIDC_ISSUER` (`https://IDEJO_ID_DOMAIN`), `_CLIENT_ID`, `_CLIENT_SECRET` (stored
  encrypted, `forum:<slug>:oidc_client_secret`), `_LABEL` ("Idejo ID") and
  `IDEJO_LOCAL_ACCOUNTS` (`forums.local_accounts`, ID-07; always on without a client). New
  forums require an Idejo ID (steward decision 2026-11-06: `Forums.defaults/0` has
  `local_accounts: false`, the create form's "Also allow local accounts" unticked); imports
  keep local accounts on, and a restore to a new subdomain takes its source's choice;
  owners and administrators keep a password sign-in either way (Idejo AC-09). On the
  forum network Caddy answers to `IDEJO_ID_DOMAIN`, so forums reach the provider inside.
- **Sign-up** (ID-02, ID-08; steward decision 2026-11-04): members' pages are under
  `/account` on `IDEJO_ID_DOMAIN` only (`Plugs.IdentityHost`, 404 elsewhere; Caddy sends
  `/account*` there to the Hub). `/account/sign-up` (`SignupController`, plain HTML, no
  JavaScript) asks email and display name; a CSS-only checkbox reveals optional first and
  last name, else "Sennoma" and "Ulo" (`Identity.placeholder_names/0`). It makes the person
  (`Identity.create_person/1`, username = email; `:exists` for a used email) and Zitadel
  emails the invite (`send_invite/1`: verify, then password or passkey on its login pages);
  the Hub never sees a password. Five per address an hour (`IdejoHub.RateLimit`, ETS);
  closed while the Hub has no SMTP. Forums lead there (steward decision 2026-11-06): Zitadel's own sign-in
  screen cannot link to it, so each forum gets Idejo's `IDEJO_OIDC_SIGN_UP_URL` (0.2.6:
  "No Idejo ID yet? Create one" under its button), this page with `return_to` its own
  `https://<host>/`; the page names that forum and, once sent, links back to its sign-in
  (`#signup-back`). Only a running forum's own `https://<host>/` is followed (no path,
  query, port or user), anything else ignored. `Identity.SetupWorker` (at boot and after an SMTP
  setting changes, retried) applies `Identity.configure/2`: Zitadel's own registration off,
  passkeys allowed, one-time codes and security keys as second factors, and the Hub's SMTP
  as its config "Idejo Hub" (sender `noreply@IDEJO_ID_DOMAIN`; removed when the Hub has none).
- **Member's page** (ID-05, ID-06; `IdejoHub.Identity.Members`, `AccountController`;
  extra review: DV-06): `https://IDEJO_ID_DOMAIN/account`, signed in through Zitadel as the
  Hub's own client ("Idejo ID account", `/account/callback`, registered by `SetupWorker`,
  secret in `identity_state` encrypted as `identity:account:client_secret`): code flow with
  PKCE, state and nonce (session `account_request`, ten minutes, used once); the code is
  exchanged at Zitadel's token endpoint inside the bundle (`Identity.exchange_code/5`) and
  the ID token's issuer, audience, azp, expiry, nonce and subject checked (OIDC Core
  3.1.3.7: straight from the provider, no key fetch). Session `member` (subject, auth time)
  for an hour. **Joined forums** come from the provider, never a forum's database: every
  sign-in is an `oidc_session.added` event (`Identity.sign_ins_since/1`, admin event API),
  read by `Members.sync/0` (each page visit, `SyncWorker` every five minutes) into
  `identity_joins` (subject, forum, `joined`/`leaving`/`left`/`deleting`/`deleted`); a
  sign-in after leaving joins again. Per forum (steward decision 2026-11-03): **Leave**
  (`idejo-admin leave --oidc-subject SUB`, account kept) or **Delete my account there**
  (`delete-account`, a box ticked), through `MemberWorker` (queue `operations`): exec in a
  running forum, a one-off `-identity` container in a suspended one, snoozed while the
  forum has a `step`; exit 0 or 2 is done; "last owner" refuses, shown on the page.
  **Delete my Idejo ID** (ID-06) needs a sign-in within five minutes (`prompt=login`) and the
  email typed: `delete-account` on every forum joined, then `Identity.delete_person/1`;
  a refusal stops it with the reason (`identity_deletions.error`; asked again, it starts
  over). Audited as `member:<subject>` (`identity.forum_leave`, `identity.forum_delete`,
  `identity.delete`), never an email.
- **Disclosure for forum owners** (SC-10, `AccountController.operator_access/2`): a public
  page on the sign-in host, `/account/operator-access` (plain HTML, linked from the member's
  page and the owner's audit log): what the operator can reach through the Hub (backups,
  their downloads, pause/restore/upgrade/export/delete, the secret key, shared SMTP, figures;
  not the live database, never owner), on the server (everything, as any hosting), and in
  Idejo IDs (emails, names, forums joined; never passwords; lock, delete, and as the
  provider's administrator could change a sign-in), and what the audit log records. Every
  statement follows how the Hub works: a change to backups, downloads, secrets, identity or
  the audit log updates that page. When they would look is the operator's own text
  (`access_policy` in Settings, plain text, at most 4000 characters, blank lines part
  paragraphs); empty, the page says the operator has not said yet.
- **Member pages' look** (steward request 2026-11-06): pages whose `Layouts.app` `title` is
  not "Idejo Hub" (the Idejo ID site, the forums directory) sit in `.idejo-member`: Idejo's
  fonts (Fraunces, Rubik; `priv/static/fonts`, OFL-1.1) and its default theme colours (gold
  on cream, `#1d1a00` in the dark theme; `assets/css/app.css`, Idejo's own formulas), the
  small Idejo logo by the title and the full one above the sign-up form
  (`priv/static/images/logo*.svg`, CC-BY-4.0; NOTICE, REUSE.toml). Operators' pages keep
  the Hub's theme. A change to Idejo's default colours or fonts is copied here. Zitadel's
  sign-in screens too: `Identity.configure/2` (`SetupWorker`, at boot) sets the instance's
  branding (label policy: Idejo's colours, light and dark, `THEME_MODE_AUTO`; the warning
  colours, login-name suffix and watermark left as they are), uploads `logo.png` /
  `logo-small.png` as its logo and icon in both themes, and activates it, only when a colour
  differs or a logo is missing (checked against Zitadel v4.20.1, 2026-11-06).
- **Member pages' standards** (Hub NF-07): every page under `/account` passes Idejo's own
  AX-01 audit (`IdejoHubWeb.Accessibility`, ported from Idejo's `test/support`;
  `test/idejo_hub_web/controllers/nf_07_member_pages_test.exs` lists the pages: a new member
  page joins it). `Layouts.app` starts with a skip link to `#main`; members' pages (any
  `title` but "Idejo Hub") end with `#member-footer` linking `/account/privacy`
  (`AccountController.privacy/2`): the operator's `privacy_notice` (Settings, plain text, at
  most 50 000 characters), or "This Hub has not published a privacy notice yet", as Idejo's
  AD-02; sign-up links it too (`#signup-privacy`). Zitadel's own sign-in screens are not
  audited here; the forum's consent screen is Idejo's (AC-09).
- **Identity administration** (HA-06, `Identity.Admin`, `IdentitiesLive` at `/identities`,
  `IdentityShowLive` at `/identities/:id`; extra review: DV-06): search Idejo IDs at the
  provider (`Identity.search_people/1`: Zitadel `POST /v2/users`, humans only, email,
  display name or username containing the text, any case, 50 at most; states `active`,
  `locked`, `inactive`, `initial`); lock one for abuse with a reason, and unlock
  (`lock_person/1`, `unlock_person/1`: `POST /v2/users/<id>/lock|unlock`; Zitadel refusing
  because it is so already counts as done): the provider then refuses its sign-ins to every
  forum and to the members' page; forum sessions already open are the forum's (bans there).
  Deletion requests: the members' own (ID-06) listed under way, stopped (with why: Retry,
  `Admin.retry/2`) or finished; one asked of the operator runs the same deletion
  (`Admin.delete/4`: the ID's email typed again, who asked and how;
  `Members.delete_identity/3` with the operator as actor). Audited `identity.lock`,
  `identity.unlock` (with `reason`), `identity.delete` (`requested`, by the operator, with
  `reason` or `retry`), by provider id (`subject`), never the email; each ID's page lists its
  entries (`Admin.log/1`). Checked against Zitadel v4.20.1 (search, lock, unlock and their
  repeats; replies in `test/idejo_hub/identity/ha_06_zitadel_test.exs`).
- **Forum email** (HN-07, `Forums.Mail`; steward request 2026-11-06): a new forum's email
  settings are the Hub's, unchanged: the shared SMTP (Settings, else `HUB_SMTP_*`) as
  `IDEJO_SMTP_*`, and the Hub's one sender, `Settings.sender/0` (Settings' **Sender
  address**, `smtp_from`, else `HUB_SMTP_FROM`, else `noreply@<Hub host>`), as
  `IDEJO_SMTP_FROM`; the forum sends under its display name. The Hub's alerts (`Mailer`) and
  Zitadel's invites (`SetupWorker`) use the same sender. `forums.mail_from` is set only when
  the operator gives a forum another address at creation (forums made before keep the
  `noreply@<host>` they were given). A forum's own SMTP is its Admin → Email (wins).
- **Owner invite** (FL-02): setup emails the owner their link; when it cannot, the link is
  in setup's output, matched only as `https://<forum host>/users/reset-password/<token>`,
  kept encrypted (`forum:<subdomain>:owner_link`) with `owner_invite: "operator"`, and
  handed out once by `Forums.take_owner_link/2` (audited `forum.owner_link.take`). The Hub
  operator is never made owner.
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
- **Every Must has a test named after its ID** (milestone 4's exit check):
  `test/idejo_hub/requirements_test.exs` reads the spec's Musts and fails on one without a
  test tagged `req: "XX-NN"` (here or in `guard/test/`) or a script `deploy/test/xx_nn_*.sh`
  / `guard/test/xx_nn_*.sh`. Its exceptions: `@elsewhere` (the BI rows, tested in Idejo
  under Idejo's IDs), `@by_review` (LB-02, the licence after legal review), `@pending`
  (remove an ID when its test lands, or the test fails). Musts built before it got their
  tests in `test/idejo_hub/earlier_musts_test.exs`.
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
# in the Hub's container: bin/hub-admin create-operator EMAIL [--role owner|operator] | reset-two-factor EMAIL (SC-08, HA-07)
# and, with the Hub running (HA-08): forums | create SUBDOMAIN NAME EMAIL | backup S | upgrade S VERSION | suspend S | resume S
(cd guard && mix precommit)  # docker-guard's own checks and tests (HN-04)
deploy/test/m2/run.sh        # milestone 2 exit check from the web interface (Docker; ~15 min)
deploy/test/m3/run.sh        # milestone 3 exit check: sign up, two forums, roles, ban, delete (~6 min)
guard/test/hn_04_chain.sh    # real chain against local Docker: harmless calls pass, dangerous refused
deploy/test/hn_08_install_settings.sh  # install.sh's settings step with a stand-in docker (CI)
deploy/test/hn_06_databases.sh         # the bundle's PostgreSQL: each role opens only its own database (CI; ~10 s)
deploy/test/nf_01_connections.sh       # the bundle's PostgreSQL holds 40 forums' connections and the Hub's (CI; ~20 s)
deploy/test/nf_02_idle_memory.sh       # an idle forum, as the Hub runs it, under 200 MB (nightly; ~12 min)
```

Production bundle (HN-08), on Debian 13 (trixie), step by step in `docs/deploying.md`:

```sh
sudo deploy/install.sh    # asks for the domains (sign-in: --id-domain, default id.<hub>,
                          # fixed once written); writes deploy/.env once; starts it all
```

`deploy/install.sh` never replaces a value already in `deploy/.env` (secrets above all). Caddy
mounts `deploy/Caddyfile` as a single file, which `git pull` replaces: a running Caddy keeps
the old one, even reloaded, so the installer restarts Caddy when what it sees differs from
the file on disk (before the health checks' wait). A new
setting the installer should fill goes into its `env_fill` list and `docs/deploying.md`.

## Steward decisions

- 2026-11-02 — Account model: shared Idejo identity (spec §5); the Hub is the OpenID Connect
  provider, each forum a client.
- 2026-11-02 — Licence: AGPL-3.0-only headers for now, same steward and CLA as Idejo.
- 2026-11-03 — OIDC provider (ID-01): **Zitadel** (AGPL-3.0) beside the Hub, at
  `id.<hub domain>` (`docs/proposals/id-01-oidc-provider.md`). Leaving a forum (ID-05): the
  person chooses to delete their account there or just leave (account and messages kept for
  a return with the same identity); Idejo gets commands for both.
- 2026-11-04 — Consent on first join (ID-09): shown by Idejo at a person's first sign-in with
  the provider (Zitadel has none). Sign-up (ID-02): the Hub runs its own page (email and display
  name required; a checkbox reveals optional first and last name, otherwise Zitadel gets
  "Sennoma" and "Ulo", which it requires); Zitadel's own sign-up form is off.
- 2026-11-03 — Docker access (HN-04): option B of `docs/proposals/hn-04-docker-access.md`.
  Only wollomatic/socket-proxy (MIT, pinned by digest) mounts the socket, read-only, and it
  allows only the listed method/path pairs. `docker-guard` (a second release from this
  repository) checks every create/exec body in front of it. The Hub reaches Docker only
  through `IdejoHub.Hosting.Docker` and never mounts the socket.
- 2026-11-03 — Forum routing (HN-02): no per-forum routes. One wildcard site sends each
  subdomain to `idejo-forum-<subdomain>:4000`; `ask` and `strict_sni_host` decide what is
  reachable (approved over the prompt's "admin API or regenerated Caddyfile").
- 2026-11-04 — Backups (OP-10, OP-02): the Hub dumps Zitadel's database itself, with
  `ZITADEL_DB_PASSWORD` (no sidecar). Off-server copies are encrypted with **age** to a
  public key (`age` binary in the image); the operator keeps the private key off the server,
  so the Hub cannot read its own off-site copies. S3 endpoint, bucket and keys come from
  `deploy/.env` (shown, not edited, in Settings). The Hub keeps the newest 14 off-site per
  forum and per Hub database, deleting older ones (its keys need delete rights).
- 2026-11-05 — FL-07 (import a standalone backup as a new forum) built ahead of "Later", at
  the steward's request: uploaded from the operator's browser; local accounts stay on; the
  standalone's `SECRET_KEY_BASE` optional (given, it moves with the data).
- Open: production domain (LB-05); read-only backup and health view for forum owners.

## Milestones (Hub spec §12)

- [x] **1 — Base Idejo ready** — Idejo milestone M6, built in the `idejo` repository. Done
  2026-11-03: Idejo `v0.1.0` published as `ghcr.io/callisto-rpg/idejo:0.1.0` (and `:0.1`).
  2026-11-04: Idejo `v0.2.0` (with AC-09 for milestone 3) published as `:0.2.0` (and `:0.2`);
  the Hub's default version until 2026-11-06: Idejo `v0.2.2` (its stylesheet checked, SC-03)
  since; Idejo `v0.2.4` (interactive release mode, Hub NF-02) from 2026-11-06; Idejo
  `v0.2.5` (the community menu); Idejo `v0.2.6` ("No Idejo ID yet? Create one"); Idejo
  `v0.2.9` (`/logo`, for the directory's cards) since.
- [x] **Foundations** (may start now, one PR) — Phoenix LiveView app, this file completed,
  SPDX headers, NOTICE, CLA check, CI (format, credo, dialyzer, sobelow, tests, deps audit,
  reuse lint), `docker-compose.yml` with Hub app, PostgreSQL and Caddy (HN-08).
- [x] **2 — Hub alpha** — FL-01 to FL-06, OP-01 to OP-05, HA-01 to HA-05, HN-01 to HN-05, HN-07,
  SC-01, SC-04 to SC-06, SC-08, SC-09; separate accounts per forum. Exit check
  `deploy/test/m2/run.sh` passed 2026-11-03 (peak 1325 MiB of the 4 GiB budget).
- [x] **3 — Shared identity** — ID-01 to ID-09, forums switched to Idejo's OIDC client. Exit
  check `deploy/test/m3/run.sh` passed 2026-11-04 (with Idejo built from #268 and #269).
- [ ] 4 — Hub 1.0 — OP-02, OP-06 to OP-10, SC-02, SC-03, SC-07, SC-10, HA-06 to HA-09, HN-06,
  Hub NF-01 to NF-07, LB-01, LB-04, operator docs.
- Later, do not start: FL-08 to FL-10, HN-03 (FL-07 built ahead: steward decision 2026-11-05).

Current milestone: **4 — Hub 1.0**, started 2026-11-04 with OP-10 and OP-02 (steward's go-ahead);
then, one PR each, the Musts in order from OP-07 (steward decision 2026-11-06).
Exit checks for each milestone are
in the Implementation Prompt, Part B.
