#!/usr/bin/env bash
# Set up the hardened build context for pufferpanel at the pinned upstream version.
# Result: build/src (Docker context: upstream source + hardening/) with
# build/src/Dockerfile.hardened, and build/build-args (KEY=VALUE lines for --build-arg).
#
# Our Dockerfile replaces upstream's, so it depends on how upstream builds. The anchors below
# are read from upstream's tree at the same tag; if any is missing, upstream changed its build
# and overlay/Dockerfile must be reviewed before the build can go on.
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: git, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream_repo="${UPSTREAM_REPO:-https://github.com/pufferpanel/pufferpanel.git}"

rm -rf "$root/build"
mkdir -p "$root/build"
git clone --quiet --depth 1 --branch "$ref" "$upstream_repo" "$src" 2>/dev/null
sha="$(git -C "$src" rev-parse HEAD)"
echo "prepare: upstream $ref @ ${sha:0:12}"
rm -rf "$src/.git" "$src/.github"

fail() { echo "prepare: $*" >&2; echo "prepare: upstream changed its build; review overlay/Dockerfile." >&2; exit 1; }
need() {  # need <description> <file> <extended regex>: must occur exactly once
  local n
  [ -f "$src/$2" ] || fail "anchor '$1': $2 is missing"
  n="$(grep -cE "$3" "$src/$2" || true)"
  [ "$n" = 1 ] || fail "anchor '$1' matched $n times in $2 (expected 1)"
}

need "node build stage"                 Dockerfile        '^FROM --platform=\$BUILDPLATFORM node:[0-9]+-alpine AS node$'
need "swag version pin"                 Dockerfile        '^ARG swagversion=[0-9.]+$'
need "swag init command"                Dockerfile        'swag init --pd --md \. -o web/swagger -g web/loader\.go$'
need "web UI copied into dist package"  Dockerfile        '^COPY --from=node /build/frontend/dist /build/pufferpanel/client/frontend/dist$'
need "cgo build of ./cmd"               Dockerfile        'go build .* github\.com/pufferpanel/pufferpanel/v3/cmd$'
need "Version/Hash via ldflags"         Dockerfile        'pufferpanel/v3\.Hash=\$sha.*pufferpanel/v3\.Version=\$version'
need "yarn workspace lock"              client/yarn.lock  '^# yarn lockfile v1$'
need "web loader imports dist package"  web/loader.go     '"github\.com/pufferpanel/pufferpanel/v3/client/frontend/dist"$'
need "dist package embeds the build"    client/frontend/public/webfiles.go '^//go:embed \*$'
need "db upgrade exits 9 when current"  entrypoint.sh     '\[ \$exitCode -eq 0 \] \|\| \[ \$exitCode -eq 9 \] \|\| exit \$exitCode'
# Upstream's release CI overwrites this file with a CurseForge API key from a secret. We don't
# have it, so CurseForge installs need daemon.curseforge.key in config.json (see README).
need "CurseForge key default empty"     config/curseforge.go '^var curseforgeKey = ""$'

node_major="$(sed -nE 's/^FROM --platform=\$BUILDPLATFORM node:([0-9]+)-alpine AS node$/\1/p' "$src/Dockerfile")"
swag_version="$(sed -nE 's/^ARG swagversion=([0-9.]+)$/\1/p' "$src/Dockerfile")"
go_min="$(sed -nE 's/^go ([0-9.]+)$/\1/p' "$src/go.mod")"
# Newest stable Go release, e.g. go1.27.4 -> 1.27.4
go_version="$(curl -fsS 'https://go.dev/dl/?mode=json' | jq -r '[.[] | select(.stable)][0].version' | sed 's/^go//')"
for v in node_major swag_version go_min go_version; do
  [ -n "${!v}" ] || { echo "prepare: could not determine $v" >&2; exit 1; }
done
[ "$(printf '%s\n%s\n' "$go_min" "$go_version" | sort -V | head -1)" = "$go_min" ] \
  || { echo "prepare: go.mod wants go $go_min, newer than the latest stable $go_version" >&2; exit 1; }
echo "prepare: node $node_major, swag $swag_version, go $go_version (go.mod: $go_min)"

mkdir -p "$src/hardening"
cp "$root/overlay/go-bump.sh" "$root/overlay/go-bumps.txt" "$src/hardening/"
cp "$root/overlay/Dockerfile" "$src/Dockerfile.hardened"

cat > "$root/build/build-args" <<EOF
NODE_IMAGE=docker.io/library/node:$node_major-alpine
GO_IMAGE=docker.io/library/golang:$go_version-trixie
RUNTIME_IMAGE=docker.io/library/debian:trixie-slim
SWAG_VERSION=$swag_version
UPSTREAM_VERSION=$ref
UPSTREAM_SHA=$sha
EOF
echo "prepare: build context ready at $src"
