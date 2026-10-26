# Multi-stage build: equip marznode with sing-box v1.13.12.
#
# Stage 1 builds sing-box from source because the official
# ghcr.io/sagernet/sing-box:latest image ships without the
# `with_v2ray_api` and `with_grpc` tags — marznode needs the former for
# user-traffic stats (FetchUsersStats) and the latter for v2ray grpc
# transports.

FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS singbox-builder

# Faster cross-compile pattern: this stage always runs natively on
# BUILDPLATFORM (no QEMU emulation for the Go toolchain). BuildKit injects
# TARGETARCH (amd64/arm64); mapped explicitly to GOARCH below.
ARG TARGETARCH

# Set to `latest` to track the newest stable sing-box release
# (resolved at build time via the GitHub releases/latest redirect),
# or pin to e.g. `1.13.18` for reproducible builds.
ARG SING_BOX_VERSION=latest
# Tag parity with dawsh/marznode's sing-box 1.11.3 build, minus tags that
# became implicit in 1.13.x (with_reality_server → with_utls, with_ech →
# stdlib). `with_musl` mirrors the official alpine-based release.
ARG SING_BOX_TAGS="with_gvisor,with_quic,with_grpc,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_v2ray_api,with_musl,badlinkname,tfogo_checklinkname0"

RUN apk add --no-cache git curl ca-certificates

# Resolve `latest` to the newest stable tag via the releases/latest redirect
# (no GitHub API token / rate-limit issues), then shallow-clone that tag.
# A pinned SING_BOX_VERSION (e.g. `1.13.18`) skips resolution. The resolved
# numeric version is saved for the ldflags Version stamp below.
RUN if [ -z "${SING_BOX_VERSION}" ] || [ "${SING_BOX_VERSION}" = "latest" ]; then \
        RESOLVED_TAG="$(curl -fsSIL -o /dev/null -w "%{url_effective}" https://github.com/SagerNet/sing-box/releases/latest | grep -o "[^/]*$")"; \
        echo "sing-box latest release: ${RESOLVED_TAG}"; \
    else \
        case "${SING_BOX_VERSION}" in v*) RESOLVED_TAG="${SING_BOX_VERSION}" ;; *) RESOLVED_TAG="v${SING_BOX_VERSION}" ;; esac; \
        echo "sing-box pinned release: ${RESOLVED_TAG}"; \
    fi && \
    echo "${RESOLVED_TAG}" > /tmp/sing-box-tag && \
    echo "${RESOLVED_TAG#v}" > /tmp/sing-box-version && \
    git clone --depth 1 --branch "${RESOLVED_TAG}" https://github.com/SagerNet/sing-box.git /src
WORKDIR /src

# -checklinkname=0 / -X internal/godebug.defaultGODEBUG=multipathtcp=0
# mirror release/LDFLAGS from upstream. Without -checklinkname=0 Go 1.23+
# rejects sing-box's linkname hooks into crypto/tls internals ("invalid
# reference to handlePostHandshakeMessage"). GOTOOLCHAIN=local pins us to
# the image's Go (go.mod may request a newer patch version).
RUN --mount=type=cache,target=/root/.cache/go-build \
    SING_BOX_STAMP="$(cat /tmp/sing-box-version)" && \
    echo "building sing-box ${SING_BOX_STAMP} for ${TARGETARCH}" && \
    GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath \
        -ldflags "-s -w -buildid= -checklinkname=0 -X internal/godebug.defaultGODEBUG=multipathtcp=0 -X github.com/sagernet/sing-box/constant.Version=${SING_BOX_STAMP}" \
        -tags "${SING_BOX_TAGS}" \
        -o /out/sing-box \
        ./cmd/sing-box

# Tag check runs the binary when possible (works in CI via QEMU binfmt from
# setup-qemu-action, even though this stage runs on BUILDPLATFORM). Falls
# back to `go version -m` arch verification for local builds without QEMU,
# where foreign-arch exec fails with "exec format error".
RUN if version_output="$(/out/sing-box version 2>&1)"; then \
        printf '%s\n' "${version_output}"; \
        for tag in $(printf '%s' "${SING_BOX_TAGS}" | tr ',' ' '); do \
            printf '%s\n' "${version_output}" | grep -F -q -- "${tag}" \
                || { echo "missing build tag in /out/sing-box: ${tag}" >&2; exit 1; }; \
        done; \
    else \
        echo "exec check unavailable (foreign arch without QEMU binfmt?), verifying GOARCH via go version -m" >&2; \
        go version -m /out/sing-box; \
        go version -m /out/sing-box | grep -q "GOARCH=${TARGETARCH}" \
            || { echo "GOARCH mismatch: expected ${TARGETARCH}" >&2; exit 1; }; \
    fi


FROM tobyxdd/hysteria:v2 AS hysteria-image

FROM python:3.12-alpine

ARG TARGETARCH

ENV PYTHONUNBUFFERED=1

COPY --from=hysteria-image /usr/local/bin/hysteria /usr/local/bin/hysteria
COPY --from=singbox-builder /out/sing-box /usr/local/bin/sing-box

WORKDIR /app

COPY . .

RUN mkdir /etc/init.d/

## Installing xray
RUN apk add --no-cache curl unzip

# TARGETARCH (amd64/arm64) -> Xray asset suffix: 64 | arm64-v8a (per
# https://github.com/XTLS/Xray-core/releases, e.g. v26.10.21 provides
# Xray-linux-64.zip and Xray-linux-arm64-v8a.zip). Keeps `latest` behavior.
RUN case "${TARGETARCH}" in \
        amd64) XRAY_ARCH="64" ;; \
        arm64) XRAY_ARCH="arm64-v8a" ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -L -H "Cache-Control: no-cache" -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" && \
    unzip xray.zip -d /usr/local/bin/ && \
    rm -f xray.zip

# Download the GeoIP and GeoSite routing databases
RUN mkdir -p /usr/local/lib/xray && \
    curl -L -o /usr/local/lib/xray/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && \
    curl -L -o /usr/local/lib/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat

# cleaning
RUN apk add --no-cache alpine-sdk libffi-dev && pip install --no-cache-dir -r /app/requirements.txt && apk del -r alpine-sdk libffi-dev curl unzip

#Run node
CMD ["python3", "marznode.py"]
