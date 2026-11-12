#!/usr/bin/env bash
# Build the offline MyriadMind release package.
#
# Produces, under $OUT:
#   myriadmind-release-$DATE/          (images/ + compose/ + scripts + MANIFEST)
#   myriadmind-release-$DATE.tar.gz
#   myriadmind-release-$DATE.sha256
#
# Usage: scripts/release/build-release.sh [--out DIR] [--date YYYYMMDD]
# Run from the repository root, after `git submodule update --init --recursive`.
set -euo pipefail

OUT="${JENKINS_HOME:-$HOME}/releases"
DATE="$(date +%Y%m%d)"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)  OUT="$2";  shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f docker-compose.yml ] && [ -d scripts/release/package ] || {
  echo "run this from the myriadmind repository root" >&2; exit 1
}

PKG=scripts/release/package
IMAGES="nanobus nanoauth nanoprovisioner nanogateway nanoportal nanoagent"
NAME="myriadmind-release-$DATE"
DEST="$OUT/$NAME"
COMMIT="$(git rev-parse HEAD)"

echo "==> source commit: $COMMIT"
echo "==> output:        $DEST"

# compose interpolates ${NANOSEC_BUS_*:?} even for `build`, so a placeholder
# .env must exist. It is never shipped in the package.
cleanup() { rm -f .env; }
trap cleanup EXIT
if [ -e .env ]; then
  echo "refusing to run: .env already exists at the repo root (would be overwritten)" >&2
  exit 1
fi
printf 'NANOSEC_BUS_INTERNAL_TOKEN=build-placeholder\nNANOSEC_BUS_DATABASE_URI=mongodb://placeholder/nanobus\n' > .env

echo "==> docker compose build"
docker compose build
echo "==> docker compose build nanosec   (profile=agent)"
docker compose build nanosec

rm -rf "$DEST"
mkdir -p "$DEST/images" "$DEST/compose"

echo "==> docker save (${IMAGES})"
for i in $IMAGES; do
  echo "    $i"
  docker save "kobeyoung81/$i:nanosec" -o "$DEST/images/$i.tar"
done

echo "==> assembling package"
cp docker-compose.yml "$DEST/compose/docker-compose.yml"
cp "$PKG/env.example"  "$DEST/compose/.env.example"
cp "$PKG/install.sh"   "$DEST/install.sh"
cp "$PKG/verify.sh"    "$DEST/verify.sh"
sed -e "s|__COMMIT__|$COMMIT|g" -e "s|__DATE__|$DATE|g" "$PKG/README-RELEASE.md" > "$DEST/README-RELEASE.md"
chmod +x "$DEST/install.sh" "$DEST/verify.sh"

{
  echo "MyriadMind offline release"
  echo "Generated : $(date -Iseconds)"
  echo "Source    : $(git config --get remote.origin.url) @ $COMMIT"
  echo "Date tag  : $DATE"
  echo
  echo "Submodule commits:"
  git submodule status | sed 's/^/  /'
  echo
  printf '%-12s %-66s %-12s %s\n' NAME IMAGE_ID BYTES SHA256
  for i in $IMAGES; do
    id="$(docker images --no-trunc --quiet "kobeyoung81/$i:nanosec")"
    bytes="$(stat -c %s "$DEST/images/$i.tar")"
    sum="$(sha256sum "$DEST/images/$i.tar" | cut -d' ' -f1)"
    printf '%-12s %-66s %-12s %s\n' "$i" "$id" "$bytes" "$sum"
  done
} > "$DEST/MANIFEST.txt"

( cd "$DEST" && sha256sum images/*.tar compose/* install.sh verify.sh README-RELEASE.md MANIFEST.txt > CHECKSUMS.sha256 )

echo "==> packing"
tar -czf "$OUT/$NAME.tar.gz" -C "$OUT" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.sha256" )

echo "==> done"
ls -lh "$OUT/$NAME.tar.gz" "$OUT/$NAME.sha256"
