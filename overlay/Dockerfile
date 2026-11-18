# Hardened PufferPanel image: upstream source at the release tag, built with current Go and
# bumped Go modules, on Debian 13 (glibc) with current packages, running as a non-root user.
#
# Build context: build/src (upstream source + hardening/), prepared by scripts/prepare.sh.
# Build args come from build/build-args.
#
# Why glibc and not upstream's Alpine image: PufferPanel's javadl downloads glibc Temurin builds,
# and Hytale's downloader and natives expect glibc. Game servers run as processes inside this
# container (PufferPanel "host" environment), so the container is their sandbox.

ARG NODE_IMAGE
ARG GO_IMAGE
ARG RUNTIME_IMAGE

###
# Web UI (embedded into the binary through the client/frontend/dist Go package)
###
FROM ${NODE_IMAGE} AS web
WORKDIR /build
COPY client/ ./
# Source maps are dropped (upstream drops the top-level ones), then directories left empty,
# which go:embed rejects.
RUN rm -rf ./*/node_modules ./*/dist \
 && yarn install --frozen-lockfile --network-timeout 600000 \
 && yarn build \
 && find frontend/dist -name '*.map' -delete \
 && find frontend/dist -mindepth 1 -type d -empty -delete

###
# Binary
###
FROM ${GO_IMAGE} AS build
ARG SWAG_VERSION
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
# Use the image's Go, never download another toolchain; cgo is needed for go-sqlite3.
ENV GOTOOLCHAIN=local CGO_ENABLED=1 GOFLAGS=-buildvcs=false
WORKDIR /src
COPY . .
COPY --from=web /build/frontend/dist client/frontend/dist
RUN sh hardening/go-bump.sh hardening/go-bumps.txt
# Swagger docs are generated at build time, as upstream does.
RUN go run "github.com/swaggo/swag/cmd/swag@v${SWAG_VERSION}" init --pd --md . -o web/swagger -g web/loader.go
RUN version="${UPSTREAM_VERSION#v}" \
 && go build -trimpath \
      -ldflags "-X 'github.com/pufferpanel/pufferpanel/v3.Hash=${UPSTREAM_SHA}' -X 'github.com/pufferpanel/pufferpanel/v3.Version=${version}'" \
      -o /out/pufferpanel ./cmd \
 && /out/pufferpanel version

###
# Runtime
###
FROM ${RUNTIME_IMAGE}
ARG UPSTREAM_VERSION
ARG UPSTREAM_SHA
ARG HARDENED_VERSION=dev
ARG HARDENED_SOURCE=
# Fixed IDs, unused on the hosts this runs on (1000 is a real user on bento).
ARG PP_UID=5657
ARG PP_GID=5657

# Same tools as the hand-built image: templates and PufferPanel operations use curl/wget,
# unzip/tar/gzip for archives, procps for stats; tini reaps game-server child processes.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates curl wget unzip tar gzip procps tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${PP_GID}" pufferpanel \
 && useradd -u "${PP_UID}" -g "${PP_GID}" -d /var/lib/pufferpanel -M -s /usr/sbin/nologin pufferpanel \
 && mkdir -p /etc/pufferpanel /var/lib/pufferpanel/servers /var/lib/pufferpanel/binaries \
             /var/lib/pufferpanel/cache /var/log/pufferpanel \
 && chown -R pufferpanel:pufferpanel /etc/pufferpanel /var/lib/pufferpanel /var/log/pufferpanel

COPY --from=build /out/pufferpanel /usr/sbin/pufferpanel

ENV GIN_MODE=release \
    PUFFER_CONFIG=/etc/pufferpanel/config.json \
    PUFFER_DOCKER_DISALLOWHOST=false \
    HOME=/var/lib/pufferpanel

LABEL org.opencontainers.image.title="pufferpanel (hardened)" \
      org.opencontainers.image.version="${HARDENED_VERSION}" \
      org.opencontainers.image.source="${HARDENED_SOURCE}" \
      org.opencontainers.image.description="PufferPanel ${UPSTREAM_VERSION} built from source with current Go/Debian, non-root" \
      io.github.pufferpanel.version="${UPSTREAM_VERSION}" \
      io.github.pufferpanel.revision="${UPSTREAM_SHA}"

WORKDIR /var/lib/pufferpanel
USER ${PP_UID}:${PP_GID}
EXPOSE 8080 5657
# Upstream's image has no health check; the web UI must answer (after `db upgrade` on start).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/ || exit 1
# `db upgrade` exits 9 when there is nothing to do.
ENTRYPOINT ["tini", "--", "sh", "-c", "pufferpanel db upgrade; rc=$?; [ $rc -eq 0 ] || [ $rc -eq 9 ] || exit $rc; exec pufferpanel run"]
