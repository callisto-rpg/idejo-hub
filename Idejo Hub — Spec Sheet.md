# Idejo Hub — Spec Sheet

Nov 2, 2026 · @Mariano

Editable copy: Claude Docs, "Idejo Hub — Spec Sheet". This Markdown file is the copy kept in the `idejo-hub` repository; requirement IDs are the same in both.

## 1. Summary

Idejo Hub is a separate control app that runs several independent Idejo forums on one VPS, each on its own subdomain (for example travel.idejo.org, tennis.idejo.org), with one shared sign-in identity and separate administration per forum.

The base Idejo release on GitHub stays single-forum. The Hub never changes forum code: it provisions, configures, backs up and upgrades ordinary Idejo instances from the outside.

**Goals**

- One operator runs many forums from one place, without touching a terminal for routine work.
- Each forum is administered by its own owner and moderators, as if it were a standalone install.
- People sign in once with an Idejo identity and join any forum on the Hub.
- A forum can leave the Hub at any time as a normal standalone Idejo install, with all its data.

**Non-goals**

- Multi-tenancy inside one Idejo process (no tenant column, no shared tables between forums).
- Federation between forums (posts, threads or moderation do not cross forums).
- Billing, plans or public self-service sign-up for new forums in the first release.
- Running forums across several servers.

## 2. Relationship to base Idejo

The Hub needs eight small changes in base Idejo, all useful to standalone installs too. None of them adds multi-forum logic to the forum code.

| ID | Change in base Idejo | Priority | Idejo spec |
| --- | --- | --- | --- |
| BI-01 | All runtime configuration from environment variables: host, database URL, upload path, SMTP defaults, secret keys | Must | AD-13 |
| BI-02 | Headless setup command (`bin/idejo-admin setup`) as an alternative to the first-run wizard | Must | AD-14 |
| BI-03 | `GET /health` JSON endpoint: version, database, migrations; 200 or 503 | Must | AD-15 |
| BI-04 | CLI backup, restore and health, non-interactive, with an exit code | Must | AD-09 (exists) |
| BI-05 | Bundled Caddy optional, so an external proxy can sit in front | Must | AD-16 |
| BI-06 | OpenID Connect client sign-in | Must if shared identity (see 5) | AC-09 (now Must) |
| BI-07 | Host-only cookies, guarded by a test | Must | SP-10 |
| BI-08 | Idle instance under 200 MB of memory | Should | NF-12 |

All of these are milestone M6 in the Idejo MVP spec, and the Idejo spec now reads "One community per instance; several instances may share a host."

The Hub depends only on these documented interfaces: environment variables, the CLI, the health endpoint and OIDC. It must keep working across Idejo minor versions without code changes.

## 3. Architecture

All forums share one proxy and one PostgreSQL server, but each runs as its own unmodified Idejo container with its own database.

```
                    Visitors, members, operator
                               │
┌─ VPS ────────────────────────▼──────────────────────────────────┐
│  Caddy reverse proxy — TLS on demand, only for hostnames         │
│  the Hub approves                                                │
│        │                 │                    │                  │
│  ┌─────▼──────┐   ┌──────▼───────┐   ┌────────▼──────────────┐   │
│  │ Idejo Hub  │   │ Identity     │   │ Forums, one Idejo     │   │
│  │ hub.…      │   │ (OIDC) id.…  │   │ container each        │   │
│  │ create,    │   │ one sign-in  │   │  travel   tennis      │   │
│  │ suspend,   │   │ for every    │   │  cars     games       │   │
│  │ backups,   │   │ forum        │   │                       │   │
│  │ upgrades,  │   │              │   │                       │   │
│  │ health     │   │              │   │                       │   │
│  └─────┬──────┘   └──────────────┘   └───────▲───────┬───────┘   │
│        └──── manages through Docker and the ─┘       │           │
│              Idejo CLI                               │           │
│  ┌───────────────────────────────────────────────────▼────────┐  │
│  │ PostgreSQL — one database and one role per forum, plus one │  │
│  │ for the Hub and identity                                   │  │
│  └────────────────────────────┬───────────────────────────────┘  │
└───────────────────────────────┼──────────────────────────────────┘
                                │ encrypted backups
                     Off-server backup storage
```

Forums sign people in through the identity provider over OIDC. The Hub never edits a forum's database directly; it works through Docker, the Idejo CLI and the health endpoint.

## 4. Forum lifecycle

A forum goes from created to live in under two minutes, and can always leave the Hub with all its data.

| ID | Requirement | Priority |
| --- | --- | --- |
| FL-01 | Create a forum from a subdomain, display name and owner email. The Hub creates its database and DB role, generates secrets, starts the instance, runs migrations, adds the proxy route and runs headless setup (BI-02). | Must |
| FL-02 | The owner receives an invite email and becomes the forum's owner on first sign-in. The Hub operator is not the owner by default. | Must |
| FL-03 | Subdomain rules: lowercase letters, digits and hyphens, 3–32 characters, not on a reserved list (hub, www, admin, mail, api, status and similar). | Must |
| FL-04 | Suspend a forum: it shows a maintenance page, data and backups are kept, and it can be resumed. | Must |
| FL-05 | Delete a forum in two steps: a final full export is made first, then deletion after a 30-day grace period unless the operator confirms immediate deletion. | Must |
| FL-06 | Export a forum as a standard Idejo backup that restores on a standalone install. | Must |
| FL-07 | Import an existing standalone Idejo backup as a new Hub forum. | Should |
| FL-08 | Rename a forum's subdomain, with a permanent redirect from the old address. | Should |
| FL-09 | Transfer ownership of a forum to another person, confirmed by both. | Should |
| FL-10 | Custom domain per forum (for example forum.tennisclub.ch), with TLS issued automatically. | Could |

Stable URIs (Idejo FD-01) include the host, so a rename or custom domain must keep old links working through redirects.

## 5. Accounts and identity

People have one Idejo identity on the Hub, and a separate membership on each forum they join. Identity is shared; profile, roles and bans are local to each forum.

*Open decision: this section assumes shared identity. The alternative is fully separate accounts per forum, which drops ID-01 to ID-05 and BI-06.*

| ID | Requirement | Priority |
| --- | --- | --- |
| ID-01 | The Hub is an OpenID Connect provider at a single sign-in address (for example id.idejo.org). Each forum is registered as an OIDC client when created. | Must |
| ID-02 | Identity holds only: email, password or passkey, display name, preferred language. Nothing forum-specific. | Must |
| ID-03 | First visit to a forum with an Idejo identity creates a local member record. The forum can still require approval or invitation, as its settings say. | Must |
| ID-04 | Roles, profile fields, bans, suspensions and moderation history stay in each forum's own database. A ban on one forum has no effect on another. | Must |
| ID-05 | A person can see which forums they have joined and leave any of them from their identity page. | Must |
| ID-06 | Deleting an identity triggers account deletion on every forum joined, following each forum's deletion rules (anonymise or remove content). | Must |
| ID-07 | Each forum can also allow local-only accounts, for people who don't want an Idejo identity. | Should |
| ID-08 | Two-factor authentication and passkeys at the identity provider. | Should |
| ID-09 | Forums never receive a password. They receive only a stable subject ID, email and display name, with consent shown on first join. | Must |

**Who manages what**

- **Hub operator:** creates, suspends, upgrades and deletes forums; manages identities only for abuse or legal requests.
- **Forum owner and admins:** everything inside their forum, as in standalone Idejo.
- **Members:** their identity on the Hub, their membership and content on each forum.

## 6. Hosting, domains and TLS

One wildcard DNS record points every subdomain at the VPS; Caddy issues certificates on demand, and only for hostnames the Hub approves.

| ID | Requirement | Priority |
| --- | --- | --- |
| HN-01 | DNS: one wildcard A/AAAA record for the forum domain, plus records for the Hub and identity hosts. No DNS change per forum. | Must |
| HN-02 | TLS through Caddy on-demand certificates. Caddy asks the Hub's "ask" endpoint before issuing; unknown hostnames are refused. | Must |
| HN-03 | Alternative: wildcard certificate through a DNS-01 challenge, for operators whose DNS provider has an API. | Could |
| HN-04 | Each forum runs as its own container from the official Idejo image, with its own environment, upload volume and memory limit. | Must |
| HN-05 | One shared PostgreSQL server; one database and one DB role per forum. A forum's role can reach only its own database. | Must |
| HN-06 | The Hub and the identity provider run in their own containers, with their own database. | Must |
| HN-07 | Outgoing email per forum: own sender address and name; SMTP either shared (set by the Hub) or the forum's own. | Must |
| HN-08 | Deployment of the Hub itself: one Docker Compose file and an install script, on the same supported OS as Idejo. | Must |

The Hub and identity provider should not sit on the apex of the project domain (see section 11).

## 7. Operations

Every upgrade is preceded by a backup and done one forum at a time, so a failed upgrade affects one forum and can be rolled back.

| ID | Requirement | Priority |
| --- | --- | --- |
| OP-01 | Scheduled backups per forum (default daily, 14 kept), using Idejo's CLI backup (BI-04). | Must |
| OP-02 | Off-server backup copy to S3-compatible storage, encrypted before upload. | Must |
| OP-03 | Restore a forum from any kept backup, to the same subdomain or a new one. | Must |
| OP-04 | Upgrade one forum: backup, pull new image, restart, wait for a healthy health check (BI-03), roll back to the previous image and backup on failure. | Must |
| OP-05 | Upgrade all forums in sequence, stopping at the first failure. | Must |
| OP-06 | Pin a forum to a version, so it is skipped by bulk upgrades. | Should |
| OP-07 | Health overview: per forum, status, version, last backup, disk use, memory use. Polled every minute. | Must |
| OP-08 | Alerts by email when a forum is down for 5 minutes, a backup fails, or disk is above 85%. | Must |
| OP-09 | Notice of new Idejo releases, with a link to the changelog. | Should |
| OP-10 | Backup of the Hub's own database and the identity provider, on the same schedule. | Must |

## 8. Security and isolation

A problem in one forum, whether a bug, a heavy load or a hostile admin, must not reach another forum's data or sessions.

| ID | Requirement | Priority |
| --- | --- | --- |
| SC-01 | Session cookies are host-only (no `Domain=` attribute), so a session on one forum is never sent to another. | Must |
| SC-02 | All subdomains are "same-site" to browsers, so SameSite cookies give no protection between forums. CSRF tokens (Idejo SP-05) are required on every state-changing request. | Must |
| SC-03 | Custom CSS (Idejo AD-11) is sanitised; no script, no `url()` to external hosts. Third-party scripts stay forbidden (Idejo SP-04). | Must |
| SC-04 | Each forum has its own secret keys, DB credentials and upload directory. No secret is shared between forums. | Must |
| SC-05 | Per-forum memory and CPU limits, so one forum cannot starve the others. | Must |
| SC-06 | Operator access to a forum's data only through logged Hub actions (backup, export, recovery CLI). No hidden admin login on forums. | Must |
| SC-07 | Audit log in the Hub: who did what to which forum, when. Visible to the operator; the part about a forum is visible to its owner. | Must |
| SC-08 | Hub operator sign-in requires two-factor authentication. | Must |
| SC-09 | The Hub's control interface is not exposed to forum admins; they manage only their own forum, inside that forum. | Must |
| SC-10 | A short disclosure page for forum owners: what the Hub operator can technically access and when they would. | Should |

## 9. Hub admin interface

The Hub is a small web app for the operator, built with the same stack as Idejo (Elixir, Phoenix LiveView), so it shares skills, tooling and visual language.

| ID | Screen or feature | Priority |
| --- | --- | --- |
| HA-01 | Forum list: subdomain, name, owner, status, version, members, last backup, disk use. Sort and filter by status. | Must |
| HA-02 | Create forum form (FL-01), with live check that the subdomain is free and valid. | Must |
| HA-03 | Forum detail page: health, backups (run, restore, download), upgrade, suspend, delete, audit log. | Must |
| HA-04 | Server page: CPU, memory, disk, PostgreSQL size, running containers. | Must |
| HA-05 | Settings: forum domain, SMTP, backup storage, alert email, reserved subdomains. | Must |
| HA-06 | Identity administration: search identities, lock an identity for abuse, handle deletion requests. | Must |
| HA-07 | Several operator accounts with roles: owner and operator. | Should |
| HA-08 | Hub CLI mirroring the main actions (create, backup, upgrade, suspend), for scripting and recovery. | Should |
| HA-09 | Interface available in the same languages as Idejo at launch. | Should |

## 10. Non-functional requirements

A 4 GB VPS should host up to about 8 small forums; the Hub itself adds under 300 MB. These figures are estimates to verify in testing.

| ID | Requirement | Priority |
| --- | --- | --- |
| NF-01 | Supported size: 1 to 30 forums per server. | Must |
| NF-02 | Memory per idle forum instance: target under 200 MB. Base Idejo NF-04 (2 GB for one forum) still applies to standalone installs. | Must |
| NF-03 | Recommended server: 4 GB RAM and 2 vCPU for up to 8 small forums; 8 GB for up to 20. | Should |
| NF-04 | Creating a forum takes under 2 minutes; upgrading one forum causes under 1 minute of downtime. | Must |
| NF-05 | The Hub being down does not take forums down. Only sign-in through the shared identity is affected; existing sessions keep working. | Must |
| NF-06 | Hub releases state which Idejo versions they support. | Must |
| NF-07 | Same accessibility and privacy standards as base Idejo for every page a member sees (identity pages, consent screen). | Must |

In the `idejo-hub` repository these are cited as "Hub NF-xx" wherever they could be confused with Idejo's own NF IDs.

## 11. Licensing and branding

The Hub is a separate program that drives Idejo only through containers, the CLI, HTTP and OIDC, which leaves room to license it separately from AGPL Idejo. This needs the planned lawyer review (Idejo LI-08) before release.

| ID | Requirement | Priority |
| --- | --- | --- |
| LB-01 | Separate repository and release cycle from base Idejo. | Must |
| LB-02 | Licence chosen after legal review: AGPL like Idejo, or a different licence for the Hub only. | Must |
| LB-03 | Every forum keeps its AGPL "Source code" link (Idejo LI-03), pointing to the exact Idejo version it runs, filled in by the Hub. | Must |
| LB-04 | Hosted forums are not presented as official project forums. Use of the Idejo name follows the trademark policy (Idejo LI-07). | Must |
| LB-05 | Hosted forums live on a separate domain from the project site (for example idejo.community rather than idejo.org), so the project site and the hosting service stay apart. | Should |

The examples in this sheet use idejo.org subdomains as in the original request; the final domain is an open decision (section 12).

## 12. Scope, open decisions and milestones

**Out of scope for the first release**

- Billing, paid plans and public self-service forum creation.
- Forums spread across several servers, or moving a forum between servers from the Hub.
- Cross-forum features: shared notifications, cross-posting, global search, global moderation.
- A Hub mobile app.

**Open decisions**

- [ ] Account model: shared Idejo identity (assumed here) or separate accounts per forum.
- [ ] Domain for hosted forums: idejo.org subdomains or a separate hosting domain (LB-05).
- [ ] Hub licence (LB-02), after legal review.
- [ ] Build the OIDC provider in the Hub, or run an existing open-source provider beside it.
- [ ] Whether forum owners get a read-only view of their forum's backups and health from inside their forum.

**Milestones**

1. **Base Idejo ready:** BI-01 to BI-05, BI-07 and BI-08 shipped in an Idejo release (Idejo milestone M6). No Hub code yet.
2. **Hub alpha:** create, suspend, delete, backup and upgrade forums from the Hub (FL-01 to FL-06, OP-01 to OP-05), separate accounts per forum.
3. **Shared identity:** OIDC provider and Idejo OIDC client (ID-01 to ID-09, BI-06).
4. **Hub 1.0:** monitoring, alerts, audit log, off-server backups, documentation for operators.
5. **Later:** import from standalone (FL-07), custom domains (FL-10), renames and transfers.
