# syntax=docker/dockerfile:1.7

ARG GO_VERSION=1.26.5
ARG ALPINE_VERSION=3.22
ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

FROM golang:${GO_VERSION}-alpine AS source

ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

RUN apk add --no-cache ca-certificates git

WORKDIR /src/tailscale

RUN test -n "${TAILSCALE_VERSION}" && \
    test -n "${TAILSCALE_COMMIT}" && \
    git clone \
      --branch "${TAILSCALE_VERSION}" \
      --depth 1 \
      https://github.com/tailscale/tailscale.git \
      . && \
    test "$(git rev-parse HEAD)" = "${TAILSCALE_COMMIT}"


FROM source AS derper-build

ARG TARGETOS=linux
ARG TARGETARCH
ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

ENV CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH}

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    version="${TAILSCALE_VERSION#v}" && \
    go build \
        -trimpath \
        -ldflags="-s -w \
          -X tailscale.com/version.longStamp=${version} \
          -X tailscale.com/version.shortStamp=${version} \
          -X tailscale.com/version.gitCommitStamp=${TAILSCALE_COMMIT}" \
        -o /out/derper \
        ./cmd/derper


FROM source AS tailscale-auth-build

ARG TARGETOS=linux
ARG TARGETARCH
ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

ENV CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH}

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    version="${TAILSCALE_VERSION#v}" && \
    ldflags="-s -w \
      -X tailscale.com/version.longStamp=${version} \
      -X tailscale.com/version.shortStamp=${version} \
      -X tailscale.com/version.gitCommitStamp=${TAILSCALE_COMMIT}" && \
    mkdir -p /out && \
    go build \
      -trimpath \
      -ldflags="${ldflags}" \
      -o /out/ \
      ./cmd/tailscale \
      ./cmd/tailscaled \
      ./cmd/containerboot


FROM alpine:${ALPINE_VERSION} AS derper

ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

RUN apk add --no-cache ca-certificates && \
    addgroup -S -g 10001 derper && \
    adduser -S -D -H -u 10001 -G derper derper && \
    install -d -o derper -g derper -m 0700 /var/lib/derper && \
    install -d -m 0755 /usr/share/licenses/tailscale

COPY --from=derper-build /out/derper /usr/local/bin/derper
COPY --from=source /src/tailscale/LICENSE /usr/share/licenses/tailscale/LICENSE

LABEL org.opencontainers.image.source="https://github.com/dz-sh/private-derper-images" \
      org.opencontainers.image.description="Minimal non-root Tailscale DERP server image" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      io.github.dz-sh.tailscale.version="${TAILSCALE_VERSION}" \
      io.github.dz-sh.tailscale.commit="${TAILSCALE_COMMIT}"

USER 10001:10001

EXPOSE 8443/tcp 3478/udp

ENTRYPOINT ["/usr/local/bin/derper"]


FROM alpine:${ALPINE_VERSION} AS tailscale-auth

ARG TAILSCALE_VERSION
ARG TAILSCALE_COMMIT

RUN apk add --no-cache ca-certificates && \
    install -d -m 0755 /var/lib/tailscale /var/run/tailscale /usr/share/licenses/tailscale

COPY --from=tailscale-auth-build /out/tailscale /usr/local/bin/tailscale
COPY --from=tailscale-auth-build /out/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale-auth-build /out/containerboot /usr/local/bin/containerboot
COPY --from=source /src/tailscale/LICENSE /usr/share/licenses/tailscale/LICENSE

LABEL org.opencontainers.image.source="https://github.com/dz-sh/private-derper-images" \
      org.opencontainers.image.description="Userspace tailscaled sidecar for DERP client verification" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      io.github.dz-sh.tailscale.version="${TAILSCALE_VERSION}" \
      io.github.dz-sh.tailscale.commit="${TAILSCALE_COMMIT}"

ENTRYPOINT ["/usr/local/bin/containerboot"]
