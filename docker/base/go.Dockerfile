# NanoSec base image: Go builder.
#
# Every Go service builds in this image instead of pulling golang:* and running
# `apk add git` itself. Three things come from here that the bare golang image
# does not give us:
#
#   * git, ca-certificates and tzdata — installed once, in one layer, instead of
#     in each of the nine service builds
#   * GOPROXY/GOFLAGS/CGO_ENABLED as environment, so the flags cannot drift
#     between services
#   * the cache directories the service builds mount with `--mount=type=cache`
#
# Build with docker/base/versions.env; see scripts/base/build-base-images.sh.
ARG GO_VERSION=1.27.4
ARG GO_ALPINE=3.24
FROM golang:${GO_VERSION}-alpine${GO_ALPINE}

ARG GO_VERSION
ARG GO_ALPINE

LABEL org.opencontainers.image.title="nanosec-base-go" \
      org.opencontainers.image.version="${GO_VERSION}-alpine${GO_ALPINE}" \
      org.opencontainers.image.source="https://gitee.com/kobeyoung81/nanosec" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

# One RUN, so the package index and cache never reach a committed layer.
RUN set -eux; \
    apk add --no-cache git ca-certificates tzdata; \
    mkdir -p /root/.cache/go-build /root/go/pkg/mod; \
    rm -rf /var/cache/apk/* /tmp/*

# GOPROXY: the build host is on a China network; goproxy.cn falls back to direct.
# GOFLAGS=-buildvcs=false: the version and commit are injected through -ldflags,
#   so a VCS stamp would only invalidate the build cache on every commit.
# CGO_ENABLED=0: every service builds a static binary on purpose.
ENV GOPROXY=https://goproxy.cn,direct \
    GO111MODULE=on \
    GOFLAGS=-buildvcs=false \
    CGO_ENABLED=0
