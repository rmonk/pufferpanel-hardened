# pufferpanel-hardened

Rebuilds upstream [PufferPanel](https://github.com/pufferpanel/pufferpanel) release tags from source as a glibc
(Debian 13) image that runs as a non-root user, with current Go, bumped Go modules and current Debian packages. Each
build is gated on a Trivy scan and a smoke test, and the result is published to `ghcr.io/rmonk/pufferpanel`.

No fork: each build clones upstream at the tag in `UPSTREAM_VERSION` and builds it with `overlay/Dockerfile`.

At v3.0.9 (tested 2026-11-17), compared with the previous hand-built image (`debian:bookworm-slim` + the release
`.deb`): Trivy findings went from 1 critical / 148 high (about 40 fixable, in the Go binary) to 0 critical / 112 high,
none fixable. The rest are Debian 13 packages with no fix released yet (`krb5` via curl, `util-linux`, …), plus
`github.com/docker/docker` and `github.com/mholt/archiver/v3` in the binary, which have no fixed release either.

## What gets changed

| | Upstream / previous image | Hardened |
|---|---|---|
| Base | upstream image: Alpine (musl); previous local image: `debian:bookworm-slim` | `debian:trixie-slim` + `apt-get upgrade`, rebuilt weekly |
| `pufferpanel` binary | release build (go1.26.4 at v3.0.9) | built from the tag with the newest stable Go; modules in `overlay/go-bumps.txt` raised to latest (same major) |
| Web UI | built by upstream CI | built from `client/` with yarn (`--frozen-lockfile`), source maps dropped, embedded in the binary as upstream does |
| User | root | `pufferpanel`, uid/gid **5657** (fixed; 1000 is a real user on bento) |

Why glibc: PufferPanel's `javadl` downloads glibc Temurin builds, and Hytale's downloader and natives expect glibc.
Game servers run as processes inside this container (PufferPanel's `host` environment), so the container is their
sandbox.

## Behavior differences

- **CurseForge:** upstream's release CI writes a CurseForge API key into `config/curseforge.go` from a secret. Builds
  from source don't have it, so CurseForge modpack installs need your own key in `config.json`
  (`"daemon": {"curseforge": {"key": "…"}}`) or `PUFFER_DAEMON_CURSEFORGE_KEY`. Nothing else uses it.
- **Non-root:** existing volumes must be owned by 5657 before the first start (see below).

## Running it

Settings that bento uses (compose):

```yaml
image: ghcr.io/rmonk/pufferpanel:latest-hardened
environment:
  - PUFFER_DOCKER_DISALLOWHOST=false        # game servers run in this container ("host" environment)
  - PUFFER_SECURITY_DISABLEUNSHARE=true     # "host" can't unshare in an unprivileged container
cap_drop: [ALL]
security_opt: [no-new-privileges:true]
volumes:
  - config:/etc/pufferpanel
  - servers:/var/lib/pufferpanel
```

Moving existing volumes from a root image, once, with the container stopped (rootful podman/docker on the host):

```bash
chown -R 5657:5657 <config volume path> <servers volume path>
```

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `v3.0.9-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 05:57 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore.yaml`, scoped to a package URL with a
  reason and an expiry date), then the smoke test, then pushes (on main only). The Trivy JSON/table output is kept as
  a build artifact. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When PufferPanel publishes a new release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

A new image restarts every game server when the container is recreated, so on bento it is **not** auto-updated:
Arcane shows the update and it is applied by hand.

## Keeping in step with upstream

Our Dockerfile replaces upstream's, so `scripts/prepare.sh` checks anchors in upstream's tree at the tag (node build
stage, swag version and command, where the web UI is embedded, the ldflags, the `db upgrade` exit codes, the empty
CurseForge default). If one is missing, the build fails instead of shipping something that only looks right. Then
compare upstream's `Dockerfile` with `overlay/Dockerfile` and adjust.

## Smoke test

`scripts/smoke-test.sh` starts the image the way bento runs it (no capabilities, `no-new-privileges`, unshare off,
fresh named volumes) and checks:
- it runs as uid 5657 and reports the upstream version
- the web UI answers; an admin created with `pufferpanel user add` can log in, and `/api/self` works
- SFTP answers with an SSH banner
- a `host` environment server installs (writes a file, downloads Java 25 with `javadl`, and `java25 -version` works)
  and starts, and its process runs as uid 5657
- a restart with the same volumes keeps the user, and the logs have no panics or permission errors

## Local build

```bash
scripts/prepare.sh
podman build -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t pufferpanel:hardened build/src
DOCKER=podman scripts/smoke-test.sh pufferpanel:hardened
```
