#!/usr/bin/env bash
# Symlinks scripts/hooks/pre-commit into the real git hooks directory so it
# runs on every commit. Uses `git rev-parse --git-common-dir` rather than
# `.git/hooks` directly because a worktree's `.git` is a file pointing at
# the main checkout, not a hooks directory of its own — hooks are shared
# across all worktrees of the same repo, so this installs once for all of
# them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

COMMON_DIR="$(git rev-parse --git-common-dir)"
# --git-common-dir can be relative to the current directory.
case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$ROOT/$COMMON_DIR" ;;
esac

HOOKS_DIR="$COMMON_DIR/hooks"
mkdir -p "$HOOKS_DIR"
ln -sf "$ROOT/scripts/hooks/pre-commit" "$HOOKS_DIR/pre-commit"
echo "installed pre-commit hook -> $HOOKS_DIR/pre-commit"
