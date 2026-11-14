# idejo Hub

idejo Hub runs several independent [idejo](https://idejo.org) forums on one server, each on its own subdomain, with one shared sign-in and separate administration per forum.

Every forum is an ordinary, unmodified idejo instance with its own database. The Hub creates, backs up, upgrades and suspends them from the outside, through idejo's documented interfaces only, so any forum can leave the Hub as a normal standalone install with all its data.

**Status:** milestone 4, Hub 1.0, under way: forums created, suspended, backed up (also off the server), restored, upgraded, imported and deleted from the Hub's pages or its command line; one shared sign-in (idejo ID) through Zitadel; health, alerts and an audit log. Install it with [docs/deploying.md](docs/deploying.md).

## Supported idejo versions

Each Hub release states the idejo versions it supports (Hub NF-06). This one: **idejo 0.3.12**, the version new forums start on (`IDEJO_DEFAULT_VERSION`). 0.2.0 was the first with the shared sign-in, 0.2.2 the first whose stylesheet is checked, 0.2.4 the first whose idle forum stays well under 200 MB (Hub NF-02), 0.2.5 the first with the community menu (the forum icon lists the other forums a member joined, and the forums directory), 0.2.6 the first whose sign-in offers "No idejo ID yet? Create one", 0.2.9 the first whose logo the forums directory can show. idejo 0.3.6 was the first with the API for the official idejo app (0.3.12 adds pinned messages and topic permissions to it), 0.3.7 the first that takes the inbox's "Save for all forums", which also reads this Hub's forums directory as JSON (HA-10). Forums on 0.2.5 run as before without that link, on 0.2.4 also without the menu; forums on 0.2.2 and 0.2.3 also use more memory; forums on 0.2.0 and 0.2.1 accept any custom CSS; forums on 0.1.0 still run, back up and upgrade, but have no member counts and no shared sign-in. Upgrade them to 0.2.9.

## Read first

- [Idejo Hub — Spec Sheet](Idejo%20Hub%20—%20Spec%20Sheet.md): what the Hub does, with requirement IDs.
- [Idejo Hub — Implementation Prompt](Idejo%20Hub%20—%20Implementation%20Prompt.md): decisions, ground rules and the order of work.
- [CLAUDE.md](CLAUDE.md): how this repository is built.

## Licence

AGPL-3.0-only for now ([LICENSE](LICENSE)); the final licence is chosen after legal review (spec LB-02). See [NOTICE](NOTICE).
