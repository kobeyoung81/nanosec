#!/bin/sh
# Print the service modules that need testing, given two super-repository
# commits: scripts/ci/changed-modules.sh [PREV] [HEAD]
#
# A module counts as changed when its gitlink moved between the two commits.
# Three things force the full list instead:
#
#   * no PREV, or PREV is not a commit we can read (first build, rewritten
#     history, a fresh clone) — better to test everything than to skip
#   * nanoprotocol changed — every Go module consumes it
#   * docker/base changed — every image is built from those toolchains
#
# The output is a space-separated list in compose order, or nothing when no
# module changed (a docs-only commit).
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

ALL="nanoadmin nanoagent nanoartifacts nanoauth nanobus nanogateway nanoportal nanoprovisioner nanoworkspace"

prev=${1:-}
head=${2:-HEAD}

if [ -z "$prev" ] || ! git rev-parse --verify --quiet "${prev}^{commit}" >/dev/null 2>&1; then
  echo "$ALL"
  exit 0
fi

if [ -n "$(git diff --name-only "$prev" "$head" -- docker/base nanoprotocol 2>/dev/null | head -1)" ]; then
  echo "$ALL"
  exit 0
fi

# `git diff --raw` prints ":<old-mode> <new-mode> <old-sha> <new-sha> <status>\t<path>";
# a submodule pointer is mode 160000 on both sides.
changed=$(git diff --raw "$prev" "$head" -- . 2>/dev/null |
          awk '$2 == "160000" { print $6 }')

out=""
for m in $ALL; do
  case " $changed " in
    *" $m "*) out="$out $m" ;;
  esac
done
echo "${out# }"
