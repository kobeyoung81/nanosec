# NanoSec base image: Node builder (the module-federation front ends).
#
# The npm registry is set here, once, instead of in five service Dockerfiles: the
# build host is on a China network and registry.npmjs.org is unreliable from it.
# `--location=global` writes $PREFIX/etc/npmrc, which survives into every RUN and
# can still be overridden per project by a repository .npmrc.
#
# Build with docker/base/versions.env; see scripts/base/build-base-images.sh.
ARG NODE_VERSION=26.13.1
ARG NODE_ALPINE=3.24
FROM node:${NODE_VERSION}-alpine${NODE_ALPINE}

ARG NODE_VERSION
ARG NODE_ALPINE

LABEL org.opencontainers.image.title="nanosec-base-node" \
      org.opencontainers.image.version="${NODE_VERSION}-alpine${NODE_ALPINE}" \
      org.opencontainers.image.source="https://gitee.com/kobeyoung81/nanosec" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN set -eux; \
    npm config set registry https://registry.npmmirror.com --location=global; \
    mkdir -p /root/.npm; \
    rm -rf /tmp/*
