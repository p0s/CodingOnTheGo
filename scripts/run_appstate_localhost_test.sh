#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_FILTER="AppStateTests/testLocalhostLoopbackUpgradeAndFallback"
TEST_FILTER="${1:-$DEFAULT_FILTER}"
SCRATCH_PATH="${COTG_APPSTATE_SCRATCH_PATH:-/tmp/cotg-appstate-$(date +%s)}"

cd "$ROOT_DIR"

export COTG_ENABLE_LOCALHOST_INTEGRATION=1

exec swift test \
  --package-path Packages/AppState \
  --filter "$TEST_FILTER" \
  --scratch-path "$SCRATCH_PATH"
