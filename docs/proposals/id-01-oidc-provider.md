# Proposal: the OpenID Connect provider (ID-01 to ID-09)

Status: **decided by the steward on 2026-11-03: B, Zitadel beside the Hub** (most secure and
least resource-intensive open-source option, after the comparison below), at
`id.<hub domain>`. See "Decision" at the end.

## What the provider must do

Idejo forums are already OIDC clients (Idejo AC-09: code flow with PKCE, `state`, `nonce`,
scopes `openid email profile`). The provider must give each forum, and only after the person
consents on first join (ID-09), a stable subject, an email and a display name; hold an
identity of email, password or passkey, display name and language (ID-02); offer two factor
and passkeys (ID-08); let people **sign up themselves**, once (the exit check); register each
forum as a client when the Hub creates it and rotate its secret (milestone 3); show a person
**the forums they joined and let them leave one** (ID-05); and **delete their accounts on
every forum** when they delete their identity (ID-06). It must fit the 4 GB server beside
four forums (the milestone-2 exit check peaked at 1325 MiB).

ID-05 and ID-06 are about the Hub's forums, not about sign-in: whichever provider is chosen,
the Hub builds them itself.

## The options

| | **A. Built into the Hub** (recommended) | **B. Zitadel beside the Hub** | **C. Keycloak beside the Hub** |
| --- | --- | --- | --- |
| Licence | Our AGPL-3.0 code; `jose` (MIT) to sign tokens, `wax_` (Apache-2.0) for passkeys | AGPL-3.0 (since v3) | Apache-2.0 |
| Memory, measured idle here (2026-11-03) | none extra: part of the Hub (a few MB) | **73 MiB** + its tables in the shared PostgreSQL | **552 MiB** (JVM) |
| Sign-up, 2FA, passkeys (ID-02, ID-08) | built by us: Argon2id and TOTP exist (SC-08); passkeys with `wax_` | all built in, passkey-first | all built in |
| Consent on first join (ID-09) | ours: one screen, the three claims named | to check (not shown by default in its hosted login) | built in |
| Forum clients (ID-01) | rows in the Hub's database, made in FL-01's job | through its management API, with a service account | through its admin API |
| Joined forums, leave, delete (ID-05, ID-06) | in the identity page we build anyway | Hub pages beside Zitadel's account pages: two places for one person | same as B |
| Maintenance | **we own security-critical protocol code**: kept to the one flow Idejo uses, and run against the OpenID Foundation's conformance suite in CI | upgrades of a second product, its API and its login UI | same, heavier |
| Moving parts | none new | one service (and its login UI), its own upgrades and backups | one heavy service |

Also looked at: **Authelia** (Apache-2.0, OpenID certified, passkeys since 4.39) and
**Kanidm** (MPL-2.0, passkey-first): neither lets people sign up themselves, which the exit
check needs. **Authentik**: sign-up and passkeys, but a Python server and worker, heavier than
Keycloak. **boruta** (MIT, the Elixir provider library): its 3.0 is still in beta
(2025-07) with one main maintainer; better to keep our own code small than to depend on it.

## Recommendation: A, built into the Hub

- **It is the smallest thing that meets all nine requirements.** Idejo uses one flow; the
  provider implements that flow only (authorization code with PKCE required, `nonce`,
  RS256 ID tokens, discovery, JWKS, userinfo), not the whole of OAuth.
- **ID-05, ID-06 and ID-09 are Hub features anyway.** With A they live in one identity page,
  one database and one audit log; with B or C a person has two account pages and the Hub keeps
  two systems in step.
- **Memory**: nothing extra on a 4 GB server. Keycloak alone would take a third of what four
  forums use.
- **The risk is ours to carry**: protocol bugs are security bugs. To hold it: the narrow flow
  above, `jose` for all cryptography (no hand-written crypto), the OpenID conformance suite
  (Basic OP profile) run in CI, and every identity change reviewed under DV-06.

If you would rather not own that code, **B (Zitadel)** is the choice: small, maintained, and
its AGPL matches the Hub's. Keycloak (C) is ruled out by memory.

## Needed from Idejo, whatever the choice

The milestone says to stop and ask before touching a forum's data. Two Idejo interfaces do
not exist yet:

1. **ID-06**: delete the account linked to an identity, following the forum's own deletion
   rules (Idejo AC-07): for example `bin/idejo-admin delete-account --oidc-subject SUB`.
2. **ID-05** "leave a forum": the same command (leaving deletes the forum account), or a
   lighter "unlink" that keeps the account but ends the link; which one is your call.

## Decision (2026-11-03)

1. **B: Zitadel** beside the Hub. Asked for the most secure and least resource-intensive
   open-source option: sign-in code from a project dedicated to it, over code of our own
   (A) or a JVM at 552 MiB (C).
2. **Address**: `id.<hub domain>`, its own host behind the bundle's Caddy.
3. **Leaving a forum (ID-05)**: the person chooses. **Delete** their account there (their
   messages then show "Deleted user", Idejo's AC-07), or **leave**: the account and its
   messages stay theirs, and joining again with the same identity gets them back.
4. **Idejo commands** for both are agreed (contract additions, reviewed in Idejo).

Measured again with Zitadel v4's separate login container (its sign-in pages run apart since
v4): **core 78 MiB + login 93 MiB = about 171 MiB** idle, plus its tables in the shared
PostgreSQL. Still far inside 4 GB with four forums (1325 MiB at the milestone-2 exit check).

Open, to settle while building: **consent on first join (ID-09)**. Zitadel shows no
per-application consent screen as far as its documentation and forums say; checked against a
running instance before ID-09 is built, and brought back to the steward if needed.
