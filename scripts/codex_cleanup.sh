#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "== Cleanup =="
git worktree prune || true
find . -name '.DS_Store' -delete
xcrun simctl delete unavailable || true
echo "== Cleanup complete =="
