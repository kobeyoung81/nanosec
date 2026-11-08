#!/bin/sh
# Install pre-commit hooks for all submodules.
# Run once after cloning the super-repo:
#   ./scripts/install-hooks.sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [ ! -f "$HOOK_SRC" ]; then
    echo "ERROR: hook script not found at $HOOK_SRC"
    exit 1
fi

echo "Installing pre-commit hooks..."

# Submodules stored in .git/modules (git worktree layout)
for repo in nanobus nanogateway nanosec nanoportal nanoprotocol nanorunner; do
    hook_dst="$REPO_ROOT/.git/modules/$repo/hooks/pre-commit"
    cp "$HOOK_SRC" "$hook_dst"
    chmod +x "$hook_dst"
    echo "  $repo"
done

# nanoauth has its own .git directory
if [ -d "$REPO_ROOT/nanoauth/.git" ]; then
    hook_dst="$REPO_ROOT/nanoauth/.git/hooks/pre-commit"
    cp "$HOOK_SRC" "$hook_dst"
    chmod +x "$hook_dst"
    echo "  nanoauth"
fi

echo "Done. Pre-commit hooks will now check GOWORK=off builds."
