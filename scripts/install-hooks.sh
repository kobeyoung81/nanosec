#!/bin/sh
# Install the pre-commit hook in every submodule of the super-repository.
# Run once after cloning, and again after a submodule is added or renamed:
#   ./scripts/install-hooks.sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$REPO_ROOT/scripts/git-hooks/pre-commit"
GITMODULES="$REPO_ROOT/.gitmodules"

if [ ! -f "$HOOK_SRC" ]; then
    echo "ERROR: hook script not found at $HOOK_SRC"
    exit 1
fi

if [ ! -f "$GITMODULES" ]; then
    echo "ERROR: $GITMODULES not found; is this the super-repository?"
    exit 1
fi

echo "Installing pre-commit hooks..."

# The list of submodules comes from .gitmodules: a hardcoded one goes stale the
# moment a service is added or renamed.
modules=$(git config -f "$GITMODULES" --get-regexp '^submodule\..*\.path$' | while read -r _key path; do
    printf '%s\n' "$path"
done)

if [ -z "$modules" ]; then
    echo "ERROR: no submodule paths found in $GITMODULES"
    exit 1
fi

installed=0
for path in $modules; do
    # A deinitialized submodule leaves an empty directory, and `git -C` would walk
    # up to the super-repository and hand back *its* hooks directory; require the
    # checkout before asking git anything.
    if [ ! -e "$REPO_ROOT/$path/.git" ]; then
        echo "ERROR: $path is not initialized; run: git submodule update --init --recursive"
        exit 1
    fi
    # Ask git where this checkout keeps its hooks instead of assuming a layout:
    # .git/modules/<path> for a normal clone, a per-worktree directory under
    # .git/worktrees/<id> when the super-repository is a linked worktree.
    if ! hook_dir=$(git -C "$REPO_ROOT/$path" rev-parse --git-path hooks 2>/dev/null); then
        echo "ERROR: cannot resolve the hooks directory of $path"
        exit 1
    fi
    case "$hook_dir" in
        /*) ;;
        *) hook_dir="$REPO_ROOT/$path/$hook_dir" ;;
    esac
    mkdir -p "$hook_dir"
    cp "$HOOK_SRC" "$hook_dir/pre-commit"
    chmod +x "$hook_dir/pre-commit"
    echo "  $path"
    installed=$((installed + 1))
done

echo "Done: $installed submodule hook(s) installed. They check GOWORK=off builds."
