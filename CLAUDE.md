<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# CLAUDE.md — Idejo Hub

Read this file before every task. Update it in the same pull request whenever a change
affects architecture, conventions, commands or milestone status (DV-01).

This is the starting version, written before any code exists. The Foundations pull request
completes it (stack details, real commands, architecture as built), modelled on Idejo's
`CLAUDE.md`.

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

## Architecture (planned; the Foundations PR confirms it)

```
lib/idejo_hub/        business logic (contexts) — no web code
lib/idejo_hub_web/    web layer — operator interface (LiveView), Caddy "ask" endpoint, identity pages
```

| Prefix | Context folder | Notes |
| --- | --- | --- |
| FL | `lib/idejo_hub/forums/` | Forum records and lifecycle; each action an Oban job with clear states |
| HN | `lib/idejo_hub/hosting/` | Docker adapter (with a fake for tests), PostgreSQL provisioning, Caddy routes, `ask` endpoint |
| OP | `lib/idejo_hub/operations/` | Backups, restore, upgrades and rollback, health polling, alerts |
| ID | `lib/idejo_hub/identity/` | OpenID Connect provider (milestone 3; provider choice still open) |
| SC | `lib/idejo_hub/audit/`, `lib/idejo_hub/secrets/` | Audit log, encrypted per-forum secrets |
| HA | `lib/idejo_hub_web/` | Operator screens; Hub CLI later (HA-08) |
| LB | — | Source link per forum (`IDEJO_SOURCE_URL`), branding rules |

Design points (Implementation Prompt, Part B, milestone 2):

- **Docker** behind one adapter module. Mounting the socket gives root on the host: the first
  milestone-2 PR proposes how to limit it (for example a socket proxy), with its licence, and
  waits for approval.
- **PostgreSQL**: the Hub's role has `CREATEDB` and `CREATEROLE`, never superuser. One
  database and one login role per forum, that role able to reach only its own database
  (HN-05). Generated passwords and `SECRET_KEY_BASE` are stored encrypted (SC-04).
- **Caddy**: the `ask` endpoint says yes only for existing, non-deleted forums and the Hub's
  own hosts (HN-02). Routes are re-applied on boot.
- **Every lifecycle step cleans up fully on failure**, and every action writes an audit entry
  from the start (SC-07 shows them in milestone 4).
- Per-forum memory and CPU limits on every container (SC-05).

## Conventions

- **SPDX header** on every source file (LI-01): `SPDX-FileCopyrightText: 2026 Mariano Pictet
  and contributors`, `SPDX-License-Identifier: AGPL-3.0-only` (steward decision, 2026-11-02;
  may change after legal review, LB-02). `reuse lint` must pass.
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
- A person reviews every PR. Identity, secrets, Docker access and anything touching sign-in
  get an extra careful human review (DV-06) — flag them in the PR description. Every OIDC
  change is in that group.
- Stop at the end of each milestone, report its exit check, and wait for the steward.

## Commands

None yet. The Foundations PR adds them (expected: `mise install`, `docker compose up -d`,
`mix setup`, `mix phx.server`, `mix test`, `mix test --only req:FL-01`, `mix precommit`,
`reuse lint`).

## Steward decisions

- 2026-11-02 — Account model: shared Idejo identity (spec §5); the Hub is the OpenID Connect
  provider, each forum a client.
- 2026-11-02 — Licence: AGPL-3.0-only headers for now, same steward and CLA as Idejo.
- 2026-11-02 — OIDC provider (built in or existing open-source beside it): **open.** Before
  milestone 3, write a one-page proposal (licence, memory, maintenance, passkeys) and wait.
- Open: production domain (LB-05); read-only backup and health view for forum owners.

## Milestones (Hub spec §12)

- [ ] **1 — Base Idejo ready** — Idejo milestone M6, built in the `idejo` repository. No Hub
  code beyond Foundations until an Idejo release with M6 exists.
- [ ] **Foundations** (may start now, one PR) — Phoenix LiveView app, this file completed,
  SPDX headers, NOTICE, CLA check, CI (format, credo, dialyzer, sobelow, tests, deps audit,
  reuse lint), `docker-compose.yml` with Hub app, PostgreSQL and Caddy (HN-08).
- [ ] 2 — Hub alpha — FL-01 to FL-06, OP-01 to OP-05, HA-01 to HA-05, HN-01 to HN-05, HN-07,
  SC-01, SC-04 to SC-06, SC-08, SC-09; separate accounts per forum.
- [ ] 3 — Shared identity — ID-01 to ID-09, forums switched to Idejo's OIDC client.
- [ ] 4 — Hub 1.0 — OP-02, OP-06 to OP-10, SC-02, SC-03, SC-07, SC-10, HA-06 to HA-09, HN-06,
  Hub NF-01 to NF-07, LB-01, LB-04, operator docs.
- Later, do not start: FL-07 to FL-10, HN-03.

Current milestone: **Foundations**, while Idejo builds M6. Exit checks for each milestone are
in the Implementation Prompt, Part B.
