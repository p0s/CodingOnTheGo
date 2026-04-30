#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH_ROOT="${COTG_COMPANION_MATRIX_SCRATCH_ROOT:-/tmp/cotg-companion-matrix-$(date +%s)}"

mkdir -p "$SCRATCH_ROOT"
cd "$ROOT_DIR"

export COTG_ENABLE_LOCALHOST_INTEGRATION="${COTG_ENABLE_LOCALHOST_INTEGRATION:-1}"

swift test \
  --package-path Packages/CompanionHost \
  --scratch-path "$SCRATCH_ROOT/CompanionHost"

swift test \
  --package-path Packages/Notifications \
  --scratch-path "$SCRATCH_ROOT/Notifications"

swift test \
  --package-path Packages/RouteSelection \
  --scratch-path "$SCRATCH_ROOT/RouteSelection"

swift test \
  --package-path Packages/AppState \
  --filter 'AppStateTests/testRestoreIngestsCompanionPublishedRoutesFromSyncMirror' \
  --scratch-path "$SCRATCH_ROOT/AppState"
