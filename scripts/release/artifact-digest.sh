#!/usr/bin/env bash
# Usage: artifact-digest.sh <service> <image-ref>
#
# Prints one digest for "what the build produced": the main binary, plus the
# built front end for the services that ship one, plus the md2pdf payload for
# the agent image. This is the release gate's unit — see docs/RELEASING.md §3
# for why it is not the image digest.
#
# Requires the image to be present locally.
set -euo pipefail

svc=${1:?usage: artifact-digest.sh <service> <image-ref>}
img=${2:?usage: artifact-digest.sh <service> <image-ref>}

case "$svc" in
  nanobus)         bin=/usr/local/bin/nanobus ;;
  nanoauth)        bin=/usr/local/bin/nanoauth;       dist=/app/ui ;;
  nanogateway)     bin=/usr/local/bin/nanogateway ;;
  nanoprovisioner) bin=/usr/local/bin/nanorunner ;;
  nanoworkspace)   bin=/usr/local/bin/nanoworkspace;   dist=/app/ui ;;
  nanoadmin)       bin=/usr/local/bin/nanoadmin;       dist=/app/ui ;;
  nanoportal)      bin=/app/nanoportal-server;         dist=/usr/share/nginx/html ;;
  nanoartifacts)   bin=/usr/local/bin/nanoartifacts;   dist=/app/web ;;
  nanoagent)       bin=/usr/local/bin/nanosec ;;
  *) echo "unknown service: $svc" >&2; exit 2 ;;
esac

lines=()

binary=$(docker run --rm --entrypoint sha256sum "$img" "$bin" | cut -d' ' -f1)
[ -n "$binary" ] || { echo "cannot read $bin from $img" >&2; exit 1; }
lines+=("binary=$binary")

if [ -n "${dist:-}" ]; then
  # @mf-types.zip is a Module Federation archive written with embedded
  # timestamps; the .d.ts files it contains are already covered.
  d=$(docker run --rm --entrypoint sh "$img" -c \
    "cd '$dist' && find . -type f ! -name '@mf-types.zip' -print0 \
       | sort -z | xargs -0 sha256sum | sha256sum" | cut -d' ' -f1)
  lines+=("dist=$d")
fi

if [ "$svc" = nanoagent ]; then
  md2pdf=$(docker run --rm --entrypoint sha256sum "$img" /usr/local/bin/md2pdf | cut -d' ' -f1)
  syntax=$(docker run --rm --entrypoint sh "$img" -c \
    "find /usr/share/md2pdf/syntax_files -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum" \
    | cut -d' ' -f1)
  lines+=("md2pdf=$md2pdf" "syntax=$syntax")
fi

printf '%s\n' "${lines[@]}" | sha256sum | cut -d' ' -f1 | sed 's/^/sha256:/'
