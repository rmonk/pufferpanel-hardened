#!/usr/bin/env bash
# Start the image the way bento runs it (non-root, no capabilities, no-new-privileges, unshare
# off, fresh named volumes), then check:
#   - it runs as uid 5657 and the version matches UPSTREAM_VERSION
#   - the web UI answers, an admin created with the CLI can log in, /api/self works
#   - SFTP answers with an SSH banner
#   - a "host" environment server installs and starts, and its process runs as uid 5657
#   - a restart with the same volumes keeps the user (login works again)
#
# Usage: scripts/smoke-test.sh <image>      (DOCKER=podman to use podman; needs curl + jq)
set -euo pipefail

image="${1:?usage: smoke-test.sh <image>}"
docker="${DOCKER:-docker}"
root="$(cd "$(dirname "$0")/.." && pwd)"
want_version="$(tr -d '[:space:]v' < "$root/UPSTREAM_VERSION")"
name="pufferpanel-smoke-$$"
http_port="${SMOKE_HTTP_PORT:-18080}"
sftp_port="${SMOKE_SFTP_PORT:-15657}"
base="http://127.0.0.1:$http_port"
jar="$(mktemp)"
email="smoke@example.com"
password="smoke-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then echo "--- logs ---"; $docker logs --tail 80 "$name" 2>&1 || true; fi
  $docker rm -f "$name" >/dev/null 2>&1 || true
  $docker volume rm -f "$name-config" "$name-data" >/dev/null 2>&1 || true
  rm -f "$jar"
  exit $rc
}
trap cleanup EXIT

start() {
  $docker run -d --name "$name" \
    --cap-drop ALL --security-opt no-new-privileges \
    -e PUFFER_SECURITY_DISABLEUNSHARE=true -e PUFFER_DOCKER_DISALLOWHOST=false \
    -v "$name-config:/etc/pufferpanel" -v "$name-data:/var/lib/pufferpanel" \
    -p "127.0.0.1:$http_port:8080" -p "127.0.0.1:$sftp_port:5657" \
    "$image" >/dev/null
  echo "smoke: waiting for web UI"
  for _ in $(seq 60); do curl -sf -o /dev/null "$base/" && return 0; sleep 1; done
  echo "smoke: FAIL web UI not up"; return 1
}

login() {
  rm -f "$jar"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -c "$jar" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')" "$base/auth/login")"
  [ "$code" = 200 ] || { echo "smoke: FAIL login returned $code"; return 1; }
  curl -sSf -b "$jar" "$base/api/self" | jq -e --arg e "$email" '.email == $e' >/dev/null \
    || { echo "smoke: FAIL /api/self after login"; return 1; }
}

api() {  # api <method> <path> [json]  -> body; fails on HTTP >= 400
  curl -sSf -b "$jar" -X "$1" -H 'Content-Type: application/json' ${3:+-d "$3"} "$base$2"
}

start

uid="$($docker exec "$name" id -u)"
[ "$uid" = 5657 ] || { echo "smoke: FAIL runs as uid $uid, expected 5657"; exit 1; }
version="$($docker exec "$name" pufferpanel version)"
grep -qF "$want_version" <<<"$version" || { echo "smoke: FAIL version '$version', expected $want_version"; exit 1; }
echo "smoke: uid 5657, $version"

$docker exec "$name" pufferpanel user add --admin --name smoke --email "$email" --password "$password" >/dev/null
login
echo "smoke: admin login and /api/self OK"

banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$sftp_port; head -c 7 <&3" || true)"
[ "$banner" = "SSH-2.0" ] || { echo "smoke: FAIL SFTP banner '$banner'"; exit 1; }
echo "smoke: SFTP banner OK"

# A minimal server in the "host" environment (what bento uses): install writes a file and
# downloads Java 25 with javadl (glibc Temurin, what the Minecraft and Hytale servers run on),
# run touches a file. Proves PufferPanel can create server dirs, install Java and spawn
# processes as non-root.
server='{
  "name": "smoke", "node": 0, "users": [],
  "type": "smoke", "display": "Smoke test",
  "data": {},
  "install": [
    { "type": "writefile", "text": "installed", "target": "installed.txt" },
    { "type": "javadl", "version": "25" }
  ],
  "run": { "command": [ { "command": "touch started-by-run" } ], "stop": "" },
  "environment": { "type": "host" }
}'
api PUT /api/servers/smoke01 "$server" >/dev/null
api POST /api/servers/smoke01/install >/dev/null
for _ in $(seq 300); do
  [ "$(api GET /api/servers/smoke01/status | jq -r '.installing')" = false ] && break; sleep 1
done
$docker exec "$name" test -f /var/lib/pufferpanel/servers/smoke01/installed.txt \
  || { echo "smoke: FAIL install did not write installed.txt"; exit 1; }
java="$($docker exec "$name" sh -c '/var/lib/pufferpanel/binaries/java25 -version 2>&1 | head -1' || true)"
grep -q 'version "25' <<<"$java" || { echo "smoke: FAIL javadl did not give a working java25 ('$java')"; exit 1; }
echo "smoke: javadl installed $java"
api POST /api/servers/smoke01/start >/dev/null
for _ in $(seq 30); do
  $docker exec "$name" test -f /var/lib/pufferpanel/servers/smoke01/started-by-run && break; sleep 1
done
owner="$($docker exec "$name" stat -c %u /var/lib/pufferpanel/servers/smoke01/started-by-run 2>/dev/null || true)"
[ "$owner" = 5657 ] || { echo "smoke: FAIL run process did not create its file as uid 5657 (got '$owner')"; exit 1; }
echo "smoke: host-environment server installed and started as uid 5657"

# stop + start with retries rather than restart: rootless podman's port forwarder can still
# hold the published ports for a moment after the container stops.
$docker stop -t 15 "$name" >/dev/null
for _ in $(seq 10); do $docker start "$name" >/dev/null 2>&1 && break; sleep 2; done
for _ in $(seq 60); do curl -sf -o /dev/null "$base/" && break; sleep 1; done
login
echo "smoke: restart with same volumes keeps the user"

logs="$($docker logs "$name" 2>&1)"
if grep -qiE 'panic:|permission denied' <<<"$logs"; then
  grep -iE 'panic:|permission denied' <<<"$logs" | head -5
  echo "smoke: FAIL panic or permission error in logs"; exit 1
fi
echo "smoke: PASS"
