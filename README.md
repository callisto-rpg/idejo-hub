# Idejo Hub

Idejo Hub runs several independent [Idejo](https://idejo.org) forums on one server, each on its own subdomain, with one shared sign-in and separate administration per forum.

Every forum is an ordinary, unmodified Idejo instance with its own database. The Hub creates, backs up, upgrades and suspends them from the outside, through Idejo's documented interfaces only, so any forum can leave the Hub as a normal standalone install with all its data.

**Status:** Foundations only: an empty Phoenix app, CI and the Compose bundle for the Hub itself. Forum management starts with milestone 2, once an Idejo release with milestone M6 ("Ready for Idejo Hub") exists.

## Read first

- [Idejo Hub — Spec Sheet](Idejo%20Hub%20—%20Spec%20Sheet.md): what the Hub does, with requirement IDs.
- [Idejo Hub — Implementation Prompt](Idejo%20Hub%20—%20Implementation%20Prompt.md): decisions, ground rules and the order of work.
- [CLAUDE.md](CLAUDE.md): how this repository is built.

## Licence

AGPL-3.0-only for now ([LICENSE](LICENSE)); the final licence is chosen after legal review (spec LB-02). See [NOTICE](NOTICE).
