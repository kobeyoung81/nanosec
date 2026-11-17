#!/usr/bin/env bash
# Usage:
#   tag-release.sh services <release> [--<service>=<version> ...] [--apply]
#   tag-release.sh super    <release> [--apply]
#   tag-release.sh branch   <major.minor> [--apply]
#
# Three steps of one release, in the order docs/RELEASING.md §6 gives them:
#
#   services  tag every service. A service with no commits since its last tag
#             keeps that tag; a changed one must be given its new version, because
#             choosing major/minor/patch is a decision, not a script's job.
#   super     tag the super-repository, after versions.lock exists and check-lock
#             passes.
#   branch    create release/<major.minor> at the highest tag of that line, in the
#             super-repository and in every service that has one.
#
# Dry run by default: it prints what it would do. `--apply` pushes.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

SERVICES=(nanoagent nanoadmin nanoartifacts nanoauth nanobus nanogateway nanoportal nanoprovisioner nanoworkspace)

apply=0
args=()
for a in "$@"; do
  if [ "$a" = "--apply" ]; then apply=1; else args+=("$a"); fi
done
mode=${args[0]:-}
target=${args[1]:-}
[ -n "$mode" ] && [ -n "$target" ] || {
  sed -n '2,22p' "$0" >&2
  exit 2
}

say() { printf '%s\n' "$*"; }
run() {
  if [ "$apply" -eq 1 ]; then say "  \$ $*"; "$@"; else say "  would run: $*"; fi
}
die() { echo "tag-release: $*" >&2; exit 1; }

semver_gt() { # semver_gt A B -> A > B ?
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

latest_tag() { git -C "$1" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true; }
exact_tag()  { git -C "$1" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true; }

case "$mode" in
  services)
    release=$target
    declare -A want
    for a in "${args[@]:2}"; do
      case "$a" in
        --*=*) svc=${a#--}; svc=${svc%%=*}; want[$svc]=${a#*=} ;;
        *) die "unknown argument $a" ;;
      esac
    done
    [[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release must look like v0.2.0"

    plan=()
    for svc in "${SERVICES[@]}"; do
      current=$(latest_tag "$svc")
      pinned=$(exact_tag "$svc")
      version=${want[$svc]:-}

      if [ -z "$version" ]; then
        [ -n "$pinned" ] || die "$svc has commits since its last tag (${current:-none}); pass --$svc=<version>"
        plan+=("$svc ${pinned#v} keep")
        continue
      fi
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$svc: '$version' is not a semantic version"
      [ -z "$(git -C "$svc" tag -l "v$version")" ] || die "$svc: tag v$version already exists (tags are immutable)"
      if [ -n "$current" ]; then
        semver_gt "$version" "${current#v}" || die "$svc: $version does not move forward from ${current#v}"
      fi
      plan+=("$svc $version new")
    done

    say "release $release"
    for p in "${plan[@]}"; do
      read -r svc version kind <<<"$p"
      printf '  %-16s v%-10s %s\n' "$svc" "$version" "$kind"
    done

    for p in "${plan[@]}"; do
      read -r svc version kind <<<"$p"
      [ "$kind" = new ] || continue
      run git -C "$svc" tag -a "v$version" -m "$svc v$version"
      run git -C "$svc" push origin "v$version"
    done
    say
    say "next: build and push the new images, then scripts/release/render-lock.sh $release"
    ;;

  super)
    release=$target
    [ -f versions.lock ] || die "versions.lock is missing: render it once the images exist"
    locked=$(jq -r '.release' versions.lock)
    [ "$locked" = "$release" ] || die "versions.lock says $locked, not $release"
    ./scripts/release/check-lock.sh || die "check-lock failed; fix the lock before tagging"
    [ -z "$(git tag -l "$release")" ] || die "tag $release already exists"
    run git tag -a "$release" -m "NanoSec $release"
    run git push origin "$release"
    ;;

  branch)
    line=$target
    [[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "branch takes a major.minor, e.g. 0.1"
    for repo in . "${SERVICES[@]}"; do
      if [ "$repo" = . ]; then ctx=(); name=nanosec; else ctx=(-C "$repo"); name=$repo; fi
      tag=$(git "${ctx[@]}" describe --tags --abbrev=0 --match "v$line.*" 2>/dev/null || true)
      [ -n "$tag" ] || { say "  $name: no v$line tag, skipped"; continue; }
      if git "${ctx[@]}" rev-parse --verify -q "refs/heads/release/$line" >/dev/null; then
        say "  $name: release/$line exists"
        continue
      fi
      run git "${ctx[@]}" branch "release/$line" "$tag"
      run git "${ctx[@]}" push origin "release/$line"
    done
    say
    say "release/$line now sits on that line's highest tag; design fixes are cherry-picked onto it."
    ;;

  *)
    die "unknown mode $mode"
    ;;
esac

[ "$apply" -eq 1 ] || say "(dry run; re-run with --apply to push)"
