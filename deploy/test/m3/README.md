<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Hub milestone 3 exit check

`deploy/test/m3/run.sh` (Docker required; run from the repository root) checks what the
Implementation Prompt asks of milestone 3: **one person signs up once, joins two forums,
holds different roles on each, is banned on one and still active on the other, then deletes
their identity and is removed from both following each forum's rules.**

1. The real bundle (`deploy/docker-compose.yml`: Hub, docker-guard, Zitadel and its login
   screen, PostgreSQL, Caddy with its local CA) plus Mailpit for email (`HUB_SMTP_*`).
2. The forums' Idejo image (`IDEJO_BASE_IMAGE`, default `ghcr.io/callisto-rpg/idejo:0.2.0`:
   it needs AC-09's consent page and `idejo-admin leave` / `delete-account`) with Caddy's
   root added to its CA list, served by a local registry.
3. The Hub configures Zitadel by itself (its own sign-up off, passkeys and second factors,
   SMTP, the member page's client).
4. Two forums, alpha and bravo, made by the Hub, each registered as an OpenID Connect client.
5. In a browser (Playwright 1.49.1, Apache-2.0), as the person: sign up on the Hub's page
   with email and display name only; open Zitadel's invite from the email and choose a
   password; sign in to alpha and bravo with "Idejo ID", each asking first what it will
   receive (email and display name), then joined.
6. Each forum's owner acts there (`bin/idejo rpc`): moderator on alpha, banned on bravo.
7. In the browser: alpha shows the moderator role; bravo refuses the same identity, banned;
   alpha still works. The member's page (`https://id.idejo.test/account`) lists both
   forums; the member deletes their Idejo ID (signed in within five minutes, email typed).
8. Both forums' accounts are anonymised by Idejo's own deletion ("Deleted user", no email,
   no identity link); Zitadel no longer has the person; the Hub's audit log has it, under
   the provider's subject.

It removes everything it made, pass or fail, and exits non-zero on any failure (keeping the
browser's screenshots in `M3_KEEP`, default `/tmp`). CI: `.github/workflows/m3-exit-check.yml`,
nightly and on demand.
