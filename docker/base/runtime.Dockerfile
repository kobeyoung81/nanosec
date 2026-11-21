# NanoSec base image: service runtime.
#
# The alpine layer every Go service runs on: CA roots (outbound TLS), tzdata
# (the services read the host timezone), and nothing else. Keeping it here means
# the nine service images share one copy of those packages instead of each
# running `apk add` in its own layer.
#
# Build with docker/base/versions.env; see scripts/base/build-base-images.sh.
ARG RUNTIME_ALPINE=3.24.4
FROM alpine:${RUNTIME_ALPINE}

ARG RUNTIME_ALPINE

LABEL org.opencontainers.image.title="nanosec-base-runtime" \
      org.opencontainers.image.version="alpine${RUNTIME_ALPINE}" \
      org.opencontainers.image.source="https://gitee.com/kobeyoung81/nanosec" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN set -eux; \
    apk add --no-cache ca-certificates tzdata; \
    rm -rf /var/cache/apk/* /tmp/*
