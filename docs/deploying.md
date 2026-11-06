<!--
SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Deploying Idejo Hub

Idejo Hub runs several Idejo forums on one server, each on its own subdomain. This page
installs it (HN-08) and lists the commands an operator needs.

## Supported Idejo versions

This Hub release supports **Idejo 0.2.5**, the version new forums start on
(`IDEJO_DEFAULT_VERSION`, below); see the [README](../README.md#supported-idejo-versions) for
older versions (Hub NF-06). Before upgrading forums to a newer Idejo, check that your Hub
release supports it.

## What you need

- A server running **Debian 13 (trixie)** (the same as Idejo). **Recommended (Hub NF-03): 4 GB
  of memory and 2 vCPU for up to 8 small forums; 8 GB for up to 20.** Measured on
  2026-11-06 with 8 idle forums on Idejo 0.2.3: the forums use about 190 MiB each (1.5 GiB
  in all; each may use up to its limit, 384 MB by default, when busy), the Hub, its
  database, Zitadel, Caddy and docker-guard about 0.9 GiB: 2.4 GiB in all, leaving room for
  the system and busy moments. CPU was not measured under load.
- **1 to 30 forums** per server (NF-01). The database is sized for 30 and some more; past 30
  the Hub warns when you add a forum, and lets you. A server set up before Idejo Hub made
  room for 30 gets it when you run `sudo deploy/install.sh` again (the database restarts, so
  every forum pauses for a few seconds); forums made before then use fewer connections once
  recreated (**Apply to all forums now** in **Settings**).
- Two domain names you control, for example `hub.example.org` for the Hub and
  `forums.example.org` for the forums.

## 1. DNS (HN-01)

Point **three records** at the server, once. Adding a forum never needs a DNS change.

| Name | Type | Value |
| --- | --- | --- |
| `hub.example.org` | A (and AAAA for IPv6) | the server's address |
| `id.hub.example.org` | A (and AAAA for IPv6) | the server's address (members' sign-in, Zitadel) |
| `*.forums.example.org` | A (and AAAA for IPv6) | the server's address |

The third one is a wildcard: `tennis.forums.example.org`, `chess.forums.example.org` and
any other forum name reach the server. Caddy gets a certificate for each forum the first
time someone visits it, after asking the Hub that the forum exists (HN-02).

The members' sign-in address is `id.<the Hub's address>` unless you choose another when
installing; it **cannot be changed afterwards** (Zitadel keeps the address it first started
with).

Everything can also sit under one domain, for example the Hub at `hub.example.com`, sign-in
at `login.example.com` and forums at `*.example.com`. Then the single `*.example.com` record
covers all three, and no forum can be named `hub` or `login`. Keep explicit records for
anything else on that domain that lives on another server (`www`, mail, a shop…): they
win over the wildcard. Reserve those names in **Settings** too, so no forum takes one. If
the site at `example.com` sets cookies for the whole domain, browsers also send them to
every forum.

## 2. Install

Log in as root or as a user with `sudo`. A fresh Debian server may not have `git` yet, so
install it first (as root, leave out `sudo`):

```sh
sudo apt update && sudo apt install -y git ca-certificates curl
git clone https://github.com/callisto-rpg/idejo-hub.git
cd idejo-hub
sudo deploy/install.sh
```

The script:

1. checks the system, installs `curl`, `openssl` and `ca-certificates` if missing, and
   Docker's own packages for Debian (with the Compose plugin) if missing, after asking;
2. asks for the Hub's address, the forum domain, the members' sign-in address (Enter keeps
   `id.<the Hub's address>`) and an email for Let's Encrypt;
3. writes `deploy/.env` (readable by root only) with new random secrets;
4. checks the DNS records above and tells you what is missing;
5. builds and starts the Hub, its database, Caddy, docker-guard and the socket proxy;
6. creates the first operator and prints their one-time password.

Run it again at any time (after an update, for example): it keeps `deploy/.env` as it is and
only adds what is missing. For a scripted install, give everything as options:

```sh
sudo deploy/install.sh --yes --hub-domain hub.example.org --forum-domain forums.example.org \
  --acme-email ops@example.org --operator ops@example.org
```

Add `--id-domain login.example.org` to choose the sign-in address (default
`id.<hub domain>`). Once `deploy/.env` has one, a different `--id-domain` is refused.

**Keep a copy of `deploy/.env` away from the server.** `HUB_SECRETS_KEY` above all: the
forums' database passwords and keys are stored encrypted with it.

## 3. Sign in

Open `https://hub.example.org`, sign in with the operator's email and password, and set up
two-factor sign-in with an authenticator app (SC-08). Then create forums from the Forums
page.

The first operator account is an **owner**. Owners also manage operator accounts on the
**Operators** page: add one (its one-time password is shown there once), make it an owner or
an operator, remove it (HA-07). Operators do everything else. The last owner always stays an
owner, and the command line below can make another at any time.

## Daily use

Everything below is on the Hub's pages (`https://hub.example.org`); most of it also on the
command line (Commands, below). Every action is recorded in the **Audit log**, and the
forum's owner sees the part about their forum from their Idejo ID page.

- **Create a forum**: **Forums** → **New forum**: its subdomain (checked while you type),
  its name and its owner's email. It is ready in about a minute; the owner is emailed a link
  to choose their password (if the email cannot be sent, the forum's page shows **Show the
  owner's link once**). You never become an owner or administrator of a forum: its owner
  runs it from inside, as on a server of their own.
- **Watch them**: the **Forums** list shows each forum's health, memory, members, size and
  last backup, checked every minute; **Server** shows the machine (load, memory, disk,
  databases). Alerts come by email (below).
- **Pause a forum**: its page → **Suspend**. Visitors see a maintenance page; nothing is
  deleted. **Resume** brings it back.
- **Back up**: every forum is backed up every night (02:00 UTC; the newest 14 kept). Its page
  → **Back up now** for one more, **Export** for a file to download.
- **Restore**: its page → an archive → **Restore here** (the forum's current data is
  replaced), or **Restore to new** with another subdomain.
- **Upgrade**: a forum's page → **Upgrade** with the version; or every running forum, one
  after another, from **Forums** → "Upgrade all running forums to" a version → **Upgrade
  all** (it stops at the first failure). Each is backed up first, and rolled back by itself
  if the new version does not start. Before upgrading, check that your Hub release supports
  that version (Supported Idejo versions, above).
- **Pin a forum to its version**: its page → **Pin to X.Y.Z**: upgrades of all forums leave
  it out, an upgrade from its own page still works (OP-06); **Unpin** to include it again.
- **Delete a forum**: its page → **Delete (30-day grace)**: a final export is made and kept,
  the forum stops, and it is purged after 30 days (**Cancel deletion** until then);
  **Delete now** asks you to type its subdomain.
- **Members' Idejo IDs**: **Idejo IDs** (below) to find one, lock it for abuse or handle a
  deletion request.
- **The forums directory**: `https://forums.<forum domain>/` lists every running forum (the
  wildcard DNS record covers it), and each forum's icon opens a menu of the other forums the
  member joined with **Find more forums** leading there (Idejo 0.2.5). A forum's page →
  **Hide from the directory** keeps it out (**Show in the directory** to list it again).

## When something goes wrong

- **A forum is down**: the list shows "down since …" and, after 5 minutes, you get an
  email. Open its page: its health and the audit log say what happened last. **Recreate
  (apply settings)** remakes its container with its data kept; **Restore here** puts back a
  backup.
- **An upgrade failed**: the Hub has already rolled it back to its previous version and the
  pre-upgrade backup; the audit log says why. Nothing to do but read it before trying again.
- **An operator lost their authenticator**: `bin/hub-admin reset-two-factor EMAIL`
  (Commands); they set it up again at their next sign-in.
- **The Hub itself is down**: forums keep running and members stay signed in (Hub NF-05);
  only new Idejo ID sign-ups, the members' page and the Hub's own pages wait. Look at
  `$H logs hub` and start it again with `$H up -d`.
- **Updating the Hub**: in the repository's directory, `git pull`, then
  `sudo deploy/install.sh` again: it keeps `deploy/.env`, rebuilds and restarts what
  changed. Forums keep running while the Hub restarts; when Caddy itself is updated, they
  are unreachable for a few seconds.
- **The disk fills up**: an alert comes above 85%. Old backups beyond the newest 14 per forum
  are removed by themselves; exports, final exports and pre-upgrade backups stay in the
  `exports` volume until you remove them.
- **The whole server is lost**: what you need from away from the server is your copy of
  `deploy/.env` (its `HUB_SECRETS_KEY` and `ZITADEL_MASTERKEY` above all), your age key, and
  the off-server copies (OP-02). On a new server: install with that `deploy/.env` in place
  (step 2), put back the identity provider's dump so members keep their Idejo IDs (Backups of
  the Hub and the identity provider, below), then bring each forum back from its decrypted
  copy with **Import a standalone backup** (below), under its old subdomain. This path has
  not been rehearsed end to end yet: try it on a spare server before you need it.

## Commands

All from the repository's directory:

```sh
H="docker compose -f deploy/docker-compose.yml --env-file deploy/.env"
$H exec hub bin/hub-admin create-operator EMAIL    # another operator (one-time password)
$H exec hub bin/hub-admin create-operator EMAIL --role owner   # another owner
$H exec hub bin/hub-admin reset-two-factor EMAIL   # an operator lost their authenticator
$H exec hub bin/hub-admin forums                   # list forums: subdomain, status, version, health
$H exec hub bin/hub-admin create SUBDOMAIN "NAME" OWNER_EMAIL
$H exec hub bin/hub-admin backup SUBDOMAIN
$H exec hub bin/hub-admin upgrade SUBDOMAIN VERSION   # backed up first, rolled back if unhealthy
$H exec hub bin/hub-admin suspend SUBDOMAIN
$H exec hub bin/hub-admin resume SUBDOMAIN
$H ps                                              # what is running
$H logs -f hub                                     # the Hub's log
```

The forum commands (HA-08) need the Hub running. Each waits for the action to end, as the
Hub's pages would show it, and exits 0 when done, 1 when it failed (with the reason) and 2
for an unknown forum, so scripts can rely on them. They are recorded in the audit log as
"command line".

## Settings in deploy/.env

| Variable | What |
| --- | --- |
| `IDEJO_HUB_DOMAIN` | The Hub's own address |
| `IDEJO_FORUM_DOMAIN` | Forums are `<name>.IDEJO_FORUM_DOMAIN` |
| `ACME_EMAIL` | Let's Encrypt notices |
| `SECRET_KEY_BASE`, `HUB_SECRETS_KEY`, `POSTGRES_PASSWORD`, `HUB_DB_PASSWORD` | Generated by the installer; never change them once forums exist |
| `IDEJO_ID_DOMAIN` | The members' sign-in address (Zitadel), `id.<IDEJO_HUB_DOMAIN>` by default. People create their Idejo ID at `https://IDEJO_ID_DOMAIN/account/sign-up`, open once the Hub has SMTP (Settings or `HUB_SMTP_*`): Zitadel sends the confirmation emails through it. At `https://IDEJO_ID_DOMAIN/account` members see the forums they joined, leave one (keeping or deleting their account there) or delete their Idejo ID |
| `ZITADEL_MASTERKEY`, `ZITADEL_DB_PASSWORD`, `ZITADEL_ADMIN_PASSWORD` | Generated by the installer. The master key encrypts Zitadel's data: never change it. The admin password signs in to Zitadel's console (`https://IDEJO_ID_DOMAIN/ui/console`, user `admin`) |
| `DOCKER_GID` | The group of the Docker socket (filled in by the installer) |
| `IDEJO_DEFAULT_VERSION` | The Idejo version new forums get (default 0.2.5: shared sign-in since 0.2.0, the stylesheet checked since 0.2.2, an idle forum well under 200 MB since 0.2.4, the community menu since 0.2.5) |
| `HUB_SMTP_*` | SMTP for forums; Settings in the Hub can set it instead |
| `IDEJO_HUB_BACKUP_CRON`, `IDEJO_HUB_BACKUPS_KEPT` | Backups of forums, the Hub's database and Zitadel's: when (default daily 02:00 UTC) and how many of each (14) |
| `IDEJO_HUB_S3_*`, `IDEJO_HUB_BACKUP_AGE_RECIPIENT` | Off-server copies of every backup (OP-02), below |
| `IDEJO_HUB_UPGRADE_HEALTH_SECONDS` | How long an upgraded forum has to become healthy before it is rolled back (300) |
| `IDEJO_HUB_RELEASES_URL`, `IDEJO_HUB_CHANGELOG_URL` | New Idejo releases (OP-09): read once a day from GitHub's list of Idejo's tags; the forum list and Server page then show a newer version than `IDEJO_DEFAULT_VERSION`, linked to what changed. Set the first, empty, to turn it off |

`deploy/.env.example` explains each one.

## Watching your forums (OP-07)

The **Forums** page is the health overview. Every minute the Hub asks each running forum
whether it is healthy (its database is reachable and up to date) and how much memory it uses:

- **Health**: *up*, or *down since* the time of the first check that found it down. Sort by
  **Health** to put forums that are down first. A forum being backed up, upgraded or restored
  is not checked until that is finished; a suspended forum shows "—".
- **Memory**: what the forum uses, of the limit set when it was created (shown in amber past
  90%).
- **Version**, **Last backup** and **Size** (database and uploads, reported by the forum every
  15 minutes) are in the same row.

The page updates by itself.

## Cookies and forms (SC-02)

Every forum lives under the same domain as the Hub, so to a browser they are the same
"site": a forum's page could send requests to the Hub with your session. The Hub refuses any
change that does not carry the token of a page it served itself, and its session cookie
(`__Host-idejo_hub`) cannot be set or replaced from a forum's address. After the update that
brought this name, operators sign in again once.

## Idejo IDs (HA-06)

**Idejo IDs**, in the header, is where you look after the shared sign-in:

- **Search** by email, name or username. Each ID's page shows its state, the forums it
  joined and what the audit log holds about it.
- **Lock** an Idejo ID for abuse (give a reason; it is kept in the audit log). Its holder can
  then sign in neither to any forum through Idejo ID nor to their Idejo ID page. A session
  already open on a forum is that forum's own: its moderators ban there. **Unlock** undoes it.
- **Deletion requests**: members delete their Idejo ID themselves from their page; the list
  shows those under way, stopped (with why, for example a forum's last owner, and **Retry**)
  and finished. When someone asks *you* (by email, by letter), open their ID, type its email
  again and say who asked and how: their account on every forum they joined is deleted as
  that forum's rules say, then the ID.

## The audit log (SC-07)

**Audit log**, in the header, lists everything done to the Hub and its forums: who did it
(an operator, a scheduled job, a member through Idejo ID), what, to which forum, when and how
it ended. Filter by forum, action (for example `forum.backup`), outcome or who; each forum's
page links to its own entries. Entries hold no secrets and are never changed or deleted.

A forum's owner sees what was done to their forum on their Idejo ID page (`/account`, under
**Forums you own**), once they sign in there with an Idejo ID whose email, verified, is the
owner email the forum was created with. Members who acted are shown only as "a member".

## Alerts by email (OP-08)

Set an **Alert email** in **Settings** (and an SMTP server there, or `HUB_SMTP_HOST` in
`deploy/.env`: alerts use the same server as forums). The Hub then writes to it, from
`noreply@` its own address, when:

- a forum has been **down for 5 minutes** (one email, and one more when it answers again);
- a **backup fails**: a forum's, the Hub's own, or an off-server copy after its last attempt;
- the disk holding the Hub's store is **above 85%** full (one email, and one more once it is
  back under 80%).

Each email, sent or not, is in the audit log (`alert.email`); one that could not be sent says
why (no alert email set, no SMTP server, or the server's answer).

## Backups of the Hub and the identity provider (OP-10)

With the forums' backups, the Hub dumps its own database (`hub-…dump`) and Zitadel's
(`zitadel-…dump`) with `pg_dump`, into the `exports` volume under `/data/exports/_hub/`,
and keeps the newest 14 of each. **Server** shows the newest of each, whether the last run
failed, and **Back up the Hub now**.

A dump alone is not enough: the Hub's secrets in it are encrypted with `HUB_SECRETS_KEY` and
Zitadel's with `ZITADEL_MASTERKEY`, both in `deploy/.env`. Keep a copy of that file away from
the server.

To put them back (on the same server, or a new one installed with the same `deploy/.env`),
with the Hub and Zitadel stopped:

```sh
H="docker compose -f deploy/docker-compose.yml --env-file deploy/.env"
$H stop hub zitadel zitadel-login
$H run --rm --no-deps -T --entrypoint cat hub /data/exports/_hub/hub-YYYYMMDD-HHMMSS.dump \
  | $H exec -T db pg_restore -U postgres --clean --if-exists -d idejo_hub
$H run --rm --no-deps -T --entrypoint cat hub /data/exports/_hub/zitadel-YYYYMMDD-HHMMSS.dump \
  | $H exec -T db pg_restore -U postgres --clean --if-exists -d zitadel
$H up -d
```

Forums are not in these dumps: restore each from its own backup (OP-03).

## Off-server copies (OP-02)

Every scheduled forum backup and every Hub dump can also go to S3-compatible storage (AWS
S3, Backblaze B2, Cloudflare R2, Scaleway, Infomaniak, a MinIO of your own…), encrypted
with [age](https://age-encryption.org) **before** it leaves the server.

1. **On your own computer**, not the server, make a key pair:
   `age-keygen -o idejo-backups.key`. It prints `Public key: age1…`. Keep
   `idejo-backups.key` safe and apart from the server, with your copy of `deploy/.env`.
   Without it no copy can be read. The Hub only ever gets the public key, so even someone
   who takes the server cannot read the off-site copies.
2. Make a bucket and an access key that can list, put and delete objects in it. The Hub
   deletes copies beyond the newest `IDEJO_HUB_BACKUPS_KEPT` (14) per forum and per Hub
   database.
3. In `deploy/.env`, set `IDEJO_HUB_S3_ENDPOINT` (for example
   `https://s3.eu-central-1.amazonaws.com`), `IDEJO_HUB_S3_REGION`, `IDEJO_HUB_S3_BUCKET`,
   optionally `IDEJO_HUB_S3_PREFIX`, `IDEJO_HUB_S3_ACCESS_KEY_ID`,
   `IDEJO_HUB_S3_SECRET_ACCESS_KEY` and `IDEJO_HUB_BACKUP_AGE_RECIPIENT` (the `age1…` key),
   then `$H up -d hub`. The Hub refuses to start if a bucket is set without a valid public
   key. **Settings** shows where copies go.

Copies are named `<prefix>forums/<subdomain>/idejo-…tar.age` and `<prefix>hub/hub-…dump.age`
/ `zitadel-…dump.age`. Each upload is in the audit log (`forum.backup.offsite`,
`hub.backup.offsite`); a failed one is tried three times, then recorded as failed.

To read a copy, download it with any S3 tool and decrypt it on a computer that has the key:

```sh
age --decrypt -i idejo-backups.key -o idejo-20261104-020000.tar idejo-20261104-020000.tar.age
```

The result is the same file as the backup on the server: a standard Idejo backup (restore
it as in "Moving a forum to a standalone Idejo" below, or put it back in the `exports`
volume), or a Hub dump (restore it as above).

## Moving a forum to a standalone Idejo (FL-06)

A forum's export is a standard Idejo backup. To run it on its own server:

1. On the forum's page in the Hub: **Export**, then **Download** the export.
2. Still there: **Show the key for a standalone restore** (recorded in the audit log). Idejo
   encrypts its push keys, and an SMTP password set in the forum's Admin → Email, with
   `SECRET_KEY_BASE`: without the same key they cannot be read.
3. Install Idejo on the new server (Idejo's own `docs/deploying.md`), and put that key in its
   `deploy/.env` as `SECRET_KEY_BASE` before the first start.
4. Copy the export into its backups volume and restore it with the app stopped:
   `bin/idejo-admin restore FILE --yes` (Idejo after 0.1.0 restores onto a new install
   directly; with 0.1.0, start the app once first so its database is migrated).

Without the key the forum's data still restores; push notifications then need
`bin/idejo-admin rotate-push-keys` and an SMTP password set in the forum must be entered again.

## Bringing a standalone Idejo forum to the Hub (FL-07)

A standalone install's backup becomes a new forum on the Hub, with its members, messages,
uploads and settings:

1. On the standalone server, make a backup and copy it out of the app's container (with
   Idejo's `idejo` shortcut from its deployment guide):

   ```sh
   idejo exec app bin/idejo-admin backup        # prints "Backup written to /data/backups/idejo-….tar"
   idejo cp app:/data/backups/idejo-YYYYMMDD-HHMMSS.tar .
   ```

   and download that file to your computer (`scp`).
2. Optionally, note the standalone install's `SECRET_KEY_BASE` (its `deploy/.env`). With it,
   the forum's push keys and an SMTP password set in its Admin → Email keep working. The key
   then belongs to the Hub forum alone: stop the standalone install. Without it, the forum
   gets its own key and new push keys (browsers subscribe again on their next visit), and an
   SMTP password set in the forum must be entered again.
3. In the Hub: **Forums → Import a standalone backup**. Choose the file, a subdomain, the
   name, the owner's email and an Idejo version at least as new as the standalone's (an older
   one refuses the backup), then **Import**.

The Hub checks that the file is an Idejo backup, creates the forum behind the maintenance
page (no setup: the backup brings its owner), restores the backup and starts it; the forum's
page shows each step. The file stays in the forum's archives as kind `import`. Members keep
signing in with their passwords (local accounts stay allowed) and can link an Idejo ID from
their profile. The forum now answers at its Hub address only: links to the old address,
including those inside messages, reach the old server.

The largest file the form takes is `IDEJO_HUB_IMPORT_MAX_MB` (default 4096) in `deploy/.env`;
while importing, the server needs about twice the file's size free.

## Applying changed settings to forums

A forum's container gets its environment when it is made. After changing email settings in
the Hub (**Settings**), use **Apply to all forums now** there, or **Recreate (apply settings)**
on one forum's page: the container is made again on the same Idejo version, with its data.
