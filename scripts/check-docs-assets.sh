#!/usr/bin/env bash
# Guard the pictures the front page points at.
#
# The rules are the ones we kept breaking by hand: an asset nobody references
# stays in the tree forever, a retired brand colour survives a repaint, and a
# PNG quietly grows past the point where a git clone hurts.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
bad() {
  printf 'FAIL  %s\n' "$*"
  fail=1
}

mds=$(printf '%s\n' README.md README.zh-CN.md)
mds="$mds $(ls docs/*.md)"
mds="$mds $(ls .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null || true)"

# 1. every asset under docs/assets is referenced by a document
for f in docs/assets/*; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  # shellcheck disable=SC2086
  if ! grep -qF -- "$base" $mds; then
    bad "docs/assets/$base is not referenced by any document"
  fi
done

# 2. retired brand colours never come back
retired=$(grep -rilE '#(2F6BFF|1E63FF|007EC6|F8FAFC)' docs/assets || true)
if [ -n "$retired" ]; then
  bad "retired colour still in: $(echo "$retired" | tr '\n' ' ')"
fi

# 3. size ceilings: vectors are cheap, screenshots are not
for f in docs/assets/*.svg; do
  [ -e "$f" ] || continue
  size=$(wc -c <"$f")
  if [ "$size" -gt 65536 ]; then
    bad "$f is ${size} bytes (ceiling 65536)"
  fi
done
for f in docs/assets/*.png; do
  [ -e "$f" ] || continue
  size=$(wc -c <"$f")
  if [ "$size" -gt 409600 ]; then
    bad "$f is ${size} bytes (ceiling 409600)"
  fi
done

# 4. everything a README points at actually exists
for ref in $(grep -hoE 'docs/assets/[A-Za-z0-9._-]+' $mds | sort -u); do
  [ -f "$ref" ] || bad "README points at a missing file: $ref"
done

# 5. every image carries alt text
for f in $mds; do
  [ -f "$f" ] || continue
  imgs=$(grep -o '<img [^>]*>' "$f" || true)
  [ -z "$imgs" ] && continue
  while IFS= read -r tag; do
    case "$tag" in
      *alt=*) ;;
      *) bad "$f has an <img> without alt: $tag" ;;
    esac
  done <<<"$imgs"
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "documentation assets: failed"
  exit 1
fi
echo "documentation assets: ok"
