#!/usr/bin/env bash
# Usage: build-release.sh [--out DIR]
#
# Packs one release for an offline host: the images a lock names, the rendered
# compose file, the installer, and a manifest with every digest. The lock is the
# input — this script never decides a version itself.
set -euo pipefail

out=${JENKINS_HOME:-$HOME}/releases
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
[ -f versions.lock ] || { echo "build-release: versions.lock is missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "build-release: jq is required" >&2; exit 1; }

release=$(jq -r '.release' versions.lock)
name="nanosec-$release"
dest="$out/$name"
mkdir -p "$dest/images"

echo "==> release $release"
echo "==> output  $dest"

echo "==> saving images"
while read -r svc; do
  image=$(jq -r --arg s "$svc" '.services[$s].image' versions.lock)
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "    $svc: $image is not present locally" >&2
    exit 1
  }
  echo "    $svc -> $(basename "${image}")"
  docker save "$image" -o "$dest/images/$svc.tar"
done < <(jq -r '.services | keys[]' versions.lock)

echo "==> rendering compose and manifests"
./scripts/release/render-manifests.sh "$dest" versions.lock >/dev/null
cp docker-compose.yml "$dest/docker-compose.yml"
cp scripts/release/package/env.example "$dest/.env.example"
cp scripts/release/package/install.sh "$dest/install.sh"
cp scripts/release/package/verify.sh "$dest/verify.sh"
cp scripts/release/package/README-RELEASE.md "$dest/README-RELEASE.md"
chmod +x "$dest/install.sh" "$dest/verify.sh"

{
  echo "NanoSec $release"
  echo "Source    : $(git config --get remote.origin.url) @ $(git rev-parse HEAD)"
  echo "Generated : $(date -Iseconds)"
  echo
  echo "Submodules:"
  git submodule status | sed 's/^/  /'
  echo
  echo "Images:"
  while read -r svc; do
    image=$(jq -r --arg s "$svc" '.services[$s].image' versions.lock)
    echo "  $(printf '%-16s' "$svc") $image"
    echo "  $(printf '%-16s' '') artifact $(jq -r --arg s "$svc" '.services[$s].artifact_digest' versions.lock)"
  done < <(jq -r '.services | keys[]' versions.lock)
} > "$dest/MANIFEST.txt"

( cd "$dest" && sha256sum images/*.tar docker-compose.yml install.sh verify.sh README-RELEASE.md MANIFEST.txt > CHECKSUMS.sha256 )

echo "==> packing"
tar -czf "$out/$name.tar.gz" -C "$out" "$name"
( cd "$out" && sha256sum "$name.tar.gz" > "$name.sha256" )
ls -lh "$out/$name.tar.gz" "$out/$name.sha256"
