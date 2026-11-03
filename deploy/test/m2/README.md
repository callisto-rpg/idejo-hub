<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Hub milestone 2 exit check

`deploy/test/m2/run.sh` (Docker required; run from the repository root) checks, from the
Hub's web interface, everything the Implementation Prompt asks of milestone 2:

1. create four forums (alpha, bravo, charlie, delta);
2. suspend and resume one (bravo; its address shows the maintenance page meanwhile);
3. back up one and restore it (alpha);
4. upgrade all four from 0.1.0 to "0.1.1", one deliberately failing (delta): delta must
   roll back alone, the other three end on 0.1.1;
5. export one (charlie), download it, and restore it on a standalone Idejo (plain
   `docker run`, no Hub): the forum's name and owner must be there;
6. delete one (delta, immediately, its subdomain typed);
7. the Hub's containers and the forums never use more than 4 GiB together (sampled every
   5 s with `docker stats`).

How it runs:

- the real bundle (`deploy/docker-compose.yml`) with Caddy's local CA instead of Let's
  Encrypt, and no published ports;
- a local registry (`registry:2.8.3`) as `IDEJO_FORUM_IMAGE`: Idejo 0.1.0, and an "0.1.1"
  built by `broken/Dockerfile` whose server refuses to start for `delta.*` only;
- a browser (Playwright 1.49.1, Apache-2.0, its Docker image) runs `browser/check.mjs`
  against `hub.idejo.test` and the forums' hosts, all leading to Caddy; it signs in with the
  operator's password and a TOTP code computed from the key the Hub shows;
- step 5 uses `IDEJO_BASE_IMAGE` (default `ghcr.io/callisto-rpg/idejo:0.1.0`).

It removes everything it made, pass or fail, and exits non-zero on any failure. CI runs it
nightly and on demand (`.github/workflows/m2-exit-check.yml`).

The 4 GiB figure is measured, not enforced: on a 4 GB VM the system and Docker need their
share too, so the budget is for what the Hub runs.
