<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Contributing to idejo Hub

Thank you for helping. idejo Hub is licensed AGPL-3.0-only for now (see `LICENSE` and
`NOTICE`; the final licence is chosen after legal review, spec LB-02).

## 1. Sign the CLA once

Before your first pull request can be merged, you sign the Contributor Licence Agreement
(LI-05). The Hub uses [idejo's CLA](https://github.com/callisto-rpg/Idejo/blob/main/docs/legal/CLA.md)
(same steward). A bot comments on your PR with a link; reply with the sentence it gives you.
You keep your copyright and grant the project steward a perpetual, worldwide, royalty-free
copyright and patent licence, including the right to relicense. A DCO sign-off alone is not
enough. Contributing for an employer? Ask them to sign the corporate version first.

## 2. One requirement per pull request

Each PR implements one requirement ID from `Idejo Hub — Spec Sheet.md`, or fixes one bug
(DV-05).

- Put the ID in the title: `FL-01: create a forum`.
- Add or update tests named and tagged with the ID (DV-02):
  ```elixir
  @tag req: "FL-01"
  test "FL-01 creating a forum provisions its database" do
  ```
- If a change needs behaviour the spec doesn't describe, open an issue first.

## 3. The Hub drives idejo only from the outside

The Hub talks to a forum only through the contract in idejo's `CLAUDE.md` → Running under
idejo Hub (environment variables, `bin/idejo-admin`, `GET /health`, OpenID Connect, the
official Docker image). It never reads or writes a forum's database. See `CLAUDE.md`.

## 4. Every file gets an SPDX header

```elixir
# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
```

Use the comment syntax of the file type. `reuse lint` must pass.

## 5. AI-assisted changes

AI tools are welcome, but a person selects, reviews and edits every change (LI-08).
Mark AI-assisted commits with a trailer on the last line of the message:

```
Assisted-by: Claude Code
```

Changes to identity, secrets, Docker access or anything touching sign-in get a line-by-line
human review (DV-06). Say so in the PR description.

## 6. Before you open the PR

```sh
mix precommit     # compile warnings, format, credo, sobelow, audits, tests, dialyzer
reuse lint
```

New dependencies must use a licence compatible with both AGPL-3.0 and a future proprietary
licence (MIT, BSD, Apache-2.0 and similar) (LI-06).

## 7. Development setup

See `CLAUDE.md` → Commands.
