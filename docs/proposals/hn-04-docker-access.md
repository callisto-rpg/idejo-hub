# Proposal: limiting the Hub's Docker access (HN-04)

Status: **waiting for the steward's decision.** No Docker code is written until it is approved
(Implementation Prompt, Part B, milestone 2 → "Docker access").

## The problem

The Hub has to start one container per forum (HN-04), so it has to talk to the Docker Engine
API. Whoever can call that API with no limits is root on the host: they can create a
container with `Privileged: true`, mount `/` from the host, or join the host's PID or network
namespace. If the Hub's `docker.sock` is mounted directly, a single bug in the Hub (or a
stolen operator session that reaches remote code execution) is a full host compromise,
including every forum's database.

Filtering by URL alone does not fix this. The Hub needs `POST /containers/create`, and that
same endpoint is the one used to create a privileged container. **The filter has to read the
request body too.** None of the widely used socket proxies does that. wollomatic's own README
says it "does not restrict … privileged containers, host namespaces, added capabilities, or
device mappings".

## What the Hub needs from Docker

Every milestone-2 action, reduced to Engine API calls (API version pinned, `/v1.xx/`):

| Need | Calls |
| --- | --- |
| Probe | `GET /_ping`, `GET /version` |
| Create, start, stop, remove a forum (FL-01, FL-04, FL-05) | `POST /containers/create`, `POST /containers/{id}/start\|stop\|wait`, `DELETE /containers/{id}`, `GET /containers/json`, `GET /containers/{id}/json` |
| Per-forum volume (HN-04) | `POST /volumes/create`, `GET /volumes/{name}`, `DELETE /volumes/{name}` |
| `bin/idejo-admin setup`, `backup`, `restore` (FL-01, OP-01, OP-03) | `POST /containers/{id}/exec`, `POST /exec/{id}/start`, `GET /exec/{id}/json`, plus a one-off container for restore |
| Copy a backup out or in (FL-06, OP-03) | `GET /containers/{id}/archive`, `PUT /containers/{id}/archive` |
| Upgrades (OP-04, OP-05) | `POST /images/create` (pull), `GET /images/{name}/json` |
| Logs for the operator (HA) | `GET /containers/{id}/logs` |

Nothing else: no `/build`, `/swarm`, `/plugins`, `/secrets`, `/system`, `/networks/create`,
`/containers/{id}/update`, `/commit` or `/session`.

## Options

| | A. Path allowlist only | B. Path allowlist + body guard (recommended) | C. Rootless Docker |
| --- | --- | --- | --- |
| What | [wollomatic/socket-proxy](https://github.com/wollomatic/socket-proxy) holds the socket; the Hub reaches it over an internal network and only the calls above are allowed | A, plus a small proxy we write (`docker-guard`) in front of it that checks every create/exec body against a fixed policy | Docker runs as an unprivileged user; the Hub may get the plain socket |
| Licence | MIT | MIT + our own AGPL-3.0-only code | Apache-2.0 (Docker itself) |
| Stops a compromised Hub from getting root? | **No**: create still accepts `Privileged` | **Yes**, as long as the guard's policy is right | **Mostly**: the attacker gets the Docker user, not root |
| Memory | ~10 MB | ~10 MB + ~50 MB (Elixir release) | none |
| Maintenance | Update an image | Update an image + ~300 lines of our own, reviewed under DV-06 | Install script sets up rootless mode; operators must keep it |
| Side effects | none | none | Client IPs are hidden behind the port driver unless `slirp4netns` is used (that breaks Idejo's IP rate limits, SP-05). CPU/IO limits (SC-05) need cgroup delegation set up by hand. Ports 80/443 need a sysctl. |

Also looked at: Tecnativa/docker-socket-proxy (Apache-2.0) only switches whole sections on
or off (`CONTAINERS=1`, `POST=1`), which is coarser than A. linuxserver/docker-socket-proxy
is GPL-3.0, which is allowed for a separate container but adds nothing over A. Docker's
authorization plugins (for example opa-docker-authz, Apache-2.0) could do B's body checks,
but they change the host's `daemon.json` and affect every container on the machine, not only
the Hub's.

## Recommendation: B

```
hub ──HTTP──▶ docker-guard ──HTTP──▶ socket-proxy ──▶ /var/run/docker.sock (read-only mount)
   network: hub-docker (internal)    network: guard-docker (internal)
```

1. **socket-proxy** (wollomatic, MIT, pinned by image digest) is the only container that
   mounts the socket. It accepts connections only from `docker-guard` (`-allowfrom`) and
   only the method/path pairs in the table above. Everything else gets 403.
2. **docker-guard** is a separate container built from this repository (`guard/`, its own
   small release), so a compromised Hub cannot change its rules. It forwards a request only
   when:
   - `containers/create`: the image is `ghcr.io/callisto-rpg/idejo` at an exact version
     (`X.Y.Z` tag or digest). `Privileged` is false. `CapAdd`, `Devices`, `DeviceRequests`,
     `SecurityOpt` overrides and `Sysctls` are empty. `NetworkMode`, `PidMode`, `IpcMode`,
     `UTSMode` and `UsernsMode` are not `host`. There are no bind mounts, only named volumes
     called `idejo-forum-<slug>-*`. The only network is `idejo-forums`. `Memory` and
     `NanoCpus` are set (SC-05). The `org.idejo.hub.forum` label is present.
   - Any call on an existing container (start, stop, exec, archive, logs, delete): the
     container has the `org.idejo.hub.forum` label. The Hub can never touch its own
     containers, PostgreSQL, Caddy or anything else on the host.
   - `exec`: `Privileged` is false, and the command starts with `bin/idejo-admin` or
     `/app/bin/idejo-admin`.
   - Volumes: create and delete only `idejo-forum-*` names. Images: pull only
     `ghcr.io/callisto-rpg/idejo`.
   - Every refusal is logged with the rule that refused it, never the body (it holds
     secrets).
3. **The Hub** sees Docker only through `IdejoHub.Hosting.Docker`, a behaviour with two
   implementations: `Docker.Engine` (HTTP to `DOCKER_HOST=http://docker-guard:2375`) and
   `Docker.Fake` (in memory, for unit tests). No Docker SDK dependency: the HTTP calls go
   through Req, which a later PR adds (Apache-2.0).
4. **Tests**: the guard's policy gets its own test file (`hn_04_docker_guard_test.exs`) with
   one rejected example for every rule above. CI also runs the real chain against a
   throwaway Docker daemon and checks that a privileged create is refused.

Why not A on its own: it reduces noise, but it does not change the "socket = root"
problem the prompt asks us to solve. Why not C as the default: it changes client IPs and
resource limits in ways that break SP-05 and SC-05 on a standard install. It can be
documented later as an extra layer for operators who want it, on top of B.

## What I need from you

1. Approve B, or choose A or C.
2. Confirm that adding wollomatic/socket-proxy (MIT) as a container in the Hub bundle is
   acceptable under LI-06.
3. Confirm that `docker-guard` may live in this repository as a second release. The
   alternative is a separate repository.

Once you answer, the next PR builds the adapter and the guard (HN-04). That PR touches Docker
access and is flagged for extra careful review (DV-06).
