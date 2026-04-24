#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "== Codex worktree setup =="
echo "Repo: $ROOT"

# Safe metadata cleanup only. Do not delete active worktrees.
git worktree prune || true

# Basic tool sanity.
command -v xcodebuild >/dev/null
command -v swift >/dev/null
command -v xcrun >/dev/null

# Resolve package dependencies for both app projects.
xcodebuild -resolvePackageDependencies \
  -project apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj \
  -scheme CodingOnTheGo >/dev/null

xcodebuild -resolvePackageDependencies \
  -project apps/macOS/CodingOnTheGoCompanion/CodingOnTheGoCompanion.xcodeproj \
  -scheme CodingOnTheGoCompanion >/dev/null

# Lightweight network sanity for this repo.
if [[ -x scripts/network_hygiene_preflight.sh ]]; then
  scripts/network_hygiene_preflight.sh localhost || true
fi

echo "== Setup complete =="
