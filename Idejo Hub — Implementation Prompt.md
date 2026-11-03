# Prompt for Claude Code — Idejo M6 and Idejo Hub

Paste the whole prompt into Claude Code. Part A runs in the `idejo` repository. Part B runs in a new `idejo-hub` repository: create it on GitHub (empty) before you start Part B, and open a separate Claude Code session there.

Edit the "Decisions" block first if any answer has changed.

---

## Decisions already made by the steward

- **Account model:** shared Idejo identity (Hub spec §5). The Hub is an OpenID Connect provider; each forum is an OIDC client. Profiles, roles and bans stay local to each forum.
- **Domain:** use `idejo.test` subdomains for development and tests. The production domain is still open (Hub LB-05); never hard-code a domain.
- **Hub licence:** AGPL-3.0-only SPDX headers for now, same steward and CLA as Idejo. The steward may change this after legal review (Hub LB-02).
- **OIDC provider:** not decided. Before building Hub milestone 3, write a one-page proposal comparing "built into the Hub" with "existing open-source provider run beside it" (licence, memory, maintenance, passkeys), and wait for the steward's answer.
- **M6 is authorised now**, even though M5 is the current milestone in `CLAUDE.md`. Do not start any other later-milestone work.

## Ground rules for both repositories

1. Read `CLAUDE.md` before every task and follow it. Requirement IDs are stable; never renumber or invent them. If something is not covered by an ID, stop and ask.
2. One requirement per pull request (DV-05), ID in the PR title, tests named after the ID (DV-02), commits ending with `Assisted-by: Claude Code` (LI-08).
3. Flag PRs touching `accounts/`, `access/`, `uploads/` or `plugs/` for extra careful human review (DV-06). Every OIDC change is in that group.
4. New dependencies only after a licence check: MIT, BSD, Apache-2.0 or similar (LI-06). Name the licence in the PR description.
5. Run `mix precommit` and `reuse lint` before every PR. Update `CLAUDE.md`, `docs/deploying.md` and `docs/admin-guide.md` in the same PR when a command, setting or label changes (DV-01).
6. Stop at the end of each milestone, report its exit check, and wait for the steward before starting the next one.

---

## Part A — Idejo milestone M6, "Ready for Idejo Hub" (repository `idejo`)

Sources: MVP spec §3 (rows AD-13 to AD-16, AC-09, SP-10, NF-12) and §7 (M6 exit check); v1 spec §13 "Running several forums on one host"; `CLAUDE.md` → "Running under Idejo Hub". Idejo must gain **no multi-forum code**: no tenant column, no list of other forums, no Hub-specific branch.

Suggested order, one PR each:

1. **SP-10 — host-only cookies.** Add a test that signs in, triggers every cookie the app sets (session, remember-me, request logger, any other) and asserts none carries a `Domain` attribute. Fix anything that does.
2. **AD-13 — configuration from environment.** Audit `config/runtime.exs`:
   - in production, refuse to start without `PHX_HOST` instead of defaulting to `example.com`;
   - add optional SMTP defaults (`IDEJO_SMTP_HOST`, `_PORT`, `_USERNAME`, `_PASSWORD`, `_FROM`), used only while the admin panel has no SMTP settings; the panel always wins;
   - make sure WebSocket `check_origin` follows `PHX_HOST`, so two instances on two hosts each accept only their own origin;
   - document every variable in `deploy/.env.example`.
3. **AD-15 — `GET /health`.** A plain controller, no sign-in, outside the browser pipeline's session. Returns JSON `{status, version, checks: {database, migrations}}`, 200 when all are ok and 503 otherwise. No personal data: do not reuse the owner check's detail text. Keep SP-05 rate limiting, sized for one request a minute from the Hub plus container health checks. Use it as the `app` service's Compose health check.
4. **AD-14 — headless setup.** `Idejo.Release.setup/1` and `bin/idejo-admin setup --name NAME --owner-email EMAIL [--registration open|invite|closed]`:
   - goes through the same code as the first-run wizard (`Idejo.Setup`), so it does nothing the wizard would not;
   - creates the owner as an invite (the owner sets their password from the email) rather than taking a password on the command line;
   - refuses with a non-zero exit code, changing nothing, when setup is already done;
   - add it to the `usage` text in `rel/overlays/bin/idejo-admin`.
5. **AD-16 — external proxy.** The default one-command install must keep its bundled Caddy. Add a documented way to run without it (a Compose profile or a second Compose file, your choice, explained in the PR). The app must trust `X-Forwarded-Proto` and `X-Forwarded-Host` only from a configured proxy address (`IDEJO_TRUSTED_PROXIES`), consistent with the existing `IdejoWeb.Plugs.ClientIp`.
6. **AC-09 — OpenID Connect client.** One provider, set by `IDEJO_OIDC_ISSUER`, `IDEJO_OIDC_CLIENT_ID`, `IDEJO_OIDC_CLIENT_SECRET`, `IDEJO_OIDC_LABEL` (button text); `IDEJO_LOCAL_ACCOUNTS=on|off` (default on).
   - Authorization code flow with PKCE, `state` and `nonce`; scopes `openid email profile`.
   - Store the link in a new table (provider issuer, subject, user_id); never key on email.
   - First sign-in creates a local member; the forum's registration mode still applies (an invite-only forum still needs an invite).
   - The provider never grants a role. Roles, profile, bans and moderation history stay local.
   - **Ask the steward before deciding** how an OIDC sign-in matches an existing local account with the same email.
   - Add the matching data model rows to the MVP spec only if the steward asks; otherwise list them in the PR description.
7. **NF-12 — idle memory.** Measure an idle production container (no one online) and record the method and figure in `docs/load-testing.md`. No enforcement yet.
8. **M6 exit check.** An automated check, runnable locally and in CI (Docker required), that:
   - starts two instances side by side behind one Caddy on `a.idejo.test` and `b.idejo.test`, each from the same image, own database and own volumes;
   - creates both with `bin/idejo-admin setup`, no wizard;
   - sees 200 from `/health` on both;
   - signs a member in to both through one test OIDC provider (a small open-source test provider, licence-checked) and gives them a different role on each;
   - shows a session cookie from one host is never sent to the other;
   - still passes the existing single-server install flow (MVP §4, "admin sets up the server").

When the exit check passes: tick M6 in `CLAUDE.md`, add the new commands to its Commands section, and stop.

---

## Part B — Idejo Hub (new repository `idejo-hub`)

Source of truth: `Idejo Hub — Spec Sheet.md` (put it at the repository root in the first PR). Hub requirement IDs: BI, FL, ID, HN, OP, SC, HA, NF, LB. Cite Hub NF IDs as "Hub NF-xx" wherever they could be confused with Idejo's.

### Hub milestone 1 — Base Idejo ready

This is Idejo's M6 (Part A). Do not start Hub milestone 2 until an Idejo release with M6 exists. The foundations below can be built meanwhile.

### Foundations (before milestone 2, one PR)

- Phoenix LiveView app on the same pinned Elixir/Erlang versions as Idejo, PostgreSQL, Oban for scheduled jobs.
- `CLAUDE.md` modelled on Idejo's: what the Hub is, specs, stack, architecture (contexts per ID prefix), conventions, workflow, commands, milestones. Include the rule "the Hub talks to Idejo only through the contract in Idejo's `CLAUDE.md` → Running under Idejo Hub; never read or write a forum's database".
- SPDX headers, NOTICE, CLA check, CI (format, credo, dialyzer, sobelow, tests, deps audit, reuse lint), copied in spirit from Idejo.
- `docker-compose.yml` for the Hub stack: Hub app, PostgreSQL (shared with forums), Caddy (HN-08).

### Hub milestone 2 — Hub alpha

FL-01 to FL-06, OP-01 to OP-05, HA-01 to HA-05, HN-01 to HN-05, HN-07, SC-01, SC-04 to SC-06, SC-08, SC-09. Separate accounts per forum at this stage.

Design points to respect:

- **Docker access.** Talk to the Docker Engine API behind one adapter module, with a fake adapter for unit tests. Mounting the Docker socket gives root on the host: propose in the first PR of this milestone how to limit it (for example a socket proxy that allows only the endpoints needed), with its licence, and wait for approval.
- **PostgreSQL.** The Hub connects with a role that has `CREATEDB` and `CREATEROLE`, not superuser. Each forum gets its own database and its own login role that can connect only to that database (HN-05). Generated passwords and `SECRET_KEY_BASE` are stored encrypted in the Hub database (SC-04).
- **Caddy.** On-demand TLS with an `ask` endpoint on the Hub that answers yes only for hosts of existing, non-deleted forums and the Hub's own hosts (HN-02). Per-forum routes through Caddy's admin API (bound to the internal network only) or a regenerated Caddyfile with reload — pick one, explain why, and make the Hub re-apply all routes on boot.
- **Lifecycle.** Each FL action is an Oban job with clear states and an audit entry (SC-07 comes in milestone 4, but record the actions from the start). Creating a forum (FL-01) = database and role, secrets, container with memory and CPU limits (SC-05), migrations (the image's own), `bin/idejo-admin setup` (AD-14), proxy route, wait for `/health` 200. Clean up fully if any step fails.
- **Backups and restore.** `bin/idejo-admin backup` inside the running container (OP-01). Restore (OP-03) stops the forum, runs `bin/idejo-admin restore FILE --yes` in a one-off container with the same environment and volumes, then starts it and waits for `/health`.
- **Upgrades (OP-04, OP-05).** Backup, pull, recreate, wait for healthy `/health` within a time limit, otherwise recreate on the previous image and restore the pre-upgrade backup.
- **Source link (LB-03).** Set `IDEJO_SOURCE_URL` per forum to the exact Idejo release it runs.
- **Suspend (FL-04).** Stop the container and route the host to a static maintenance page served by Caddy.

Exit check: from the Hub's web interface, create four forums, suspend and resume one, back up and restore one, upgrade all four from one Idejo version to the next with one deliberately failing (it must roll back alone), export one and restore that export on a standalone Idejo install, delete one. All on a single 4 GB test VM.

### Hub milestone 3 — Shared identity

ID-01 to ID-09, plus switching each forum to Idejo's OIDC client (AC-09) through its environment. Start with the provider proposal described in "Decisions". The Hub registers each forum as an OIDC client at creation and rotates client secrets on demand. ID-06 (deleting an identity deletes the forum accounts) works through a documented Idejo interface; if Idejo has none, stop and ask rather than touching a forum's database.

Exit check: one person signs up once, joins two forums, holds different roles on each, is banned on one and still active on the other, then deletes their identity and is removed from both following each forum's rules.

### Hub milestone 4 — Hub 1.0

OP-02, OP-06 to OP-10, SC-02, SC-03, SC-07, SC-10, HA-06 to HA-09, HN-06, Hub NF-01 to NF-07, LB-01, LB-04, operator documentation (install, daily use, recovery). Load-check Hub NF-02 and NF-03 on a 4 GB VM with 8 idle forums and report the figures.

Exit check: every Must in the Hub spec has a passing test named after its ID; a fresh VPS goes from empty to a running Hub with two forums by following the operator docs alone.

### Later (do not start)

FL-07 to FL-10, HN-03.
