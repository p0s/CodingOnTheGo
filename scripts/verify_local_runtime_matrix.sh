#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_DESTINATION="${MAC_DESTINATION:-platform=macOS}"
SCRATCH_ROOT="${SCRATCH_ROOT:-/tmp/cotg-verify-$(date +%Y%m%d%H%M%S)}"
WORKSPACE_ROOT="${COTG_WORKSPACE_ROOT:-$ROOT_DIR}"
WORKTREE_ROOT="${COTG_WORKTREE_ROOT:-$(dirname "$ROOT_DIR")}"
LOCALHOST_RAW_KEY_PATH="${COTG_TEST_SSH_RAW_KEY_PATH:-/tmp/cotg_app_test_key.raw}"
IOS_DESTINATION="${IOS_DESTINATION:-}"
IPAD_DESTINATION="${IPAD_DESTINATION:-}"
IOS_CI_SCHEME="${IOS_CI_SCHEME:-CodingOnTheGoCI}"
IPAD_SCHEME="${IPAD_SCHEME:-CodingOnTheGoPad}"
IPAD_LAYOUT_PLAN="${IPAD_LAYOUT_PLAN:-LocalIPadLayout}"
NO_PROXY_DEFAULTS="localhost,127.0.0.1,::1,.local,10.,192.168.,172.16.,172.17.,172.18.,172.19.,172.20.,172.21.,172.22.,172.23.,172.24.,172.25.,172.26.,172.27.,172.28.,172.29.,172.30.,172.31.,.ts.net,100.64."

cd "$ROOT_DIR"
export COTG_WORKSPACE_ROOT="$WORKSPACE_ROOT"
export COTG_WORKTREE_ROOT="$WORKTREE_ROOT"
export COTG_ENABLE_LOCALHOST_INTEGRATION="${COTG_ENABLE_LOCALHOST_INTEGRATION:-1}"
export COTG_ENABLE_KEYCHAIN_TESTS="${COTG_ENABLE_KEYCHAIN_TESTS:-1}"
export COTG_TEST_SSH_RAW_KEY_PATH="$LOCALHOST_RAW_KEY_PATH"
export COTG_TEST_SSH_USER="${COTG_TEST_SSH_USER:-$(id -un)}"
if [[ -n "${NO_PROXY:-}" ]]; then
  export NO_PROXY="${NO_PROXY},${NO_PROXY_DEFAULTS}"
else
  export NO_PROXY="${NO_PROXY_DEFAULTS}"
fi
export no_proxy="${NO_PROXY}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command jq
require_command swift
require_command xcodebuild
require_command xcodegen
require_command xcrun
require_command codex

"$ROOT_DIR/scripts/network_hygiene_preflight.sh" lan

if [[ "$COTG_ENABLE_LOCALHOST_INTEGRATION" == "1" ]]; then
  require_command ssh
  [[ -f "$LOCALHOST_RAW_KEY_PATH" ]] || {
    echo "Missing localhost raw SSH key at $LOCALHOST_RAW_KEY_PATH" >&2
    echo "Expected a 32-byte Ed25519 seed file for the clearly marked localhost test credential." >&2
    exit 1
  }
fi

if [[ -z "$IOS_DESTINATION" ]]; then
  IOS_DESTINATION="$("$ROOT_DIR/scripts/resolve_simulator_destination.sh" iphone)"
fi

if [[ -z "$IPAD_DESTINATION" ]]; then
  IPAD_DESTINATION="$("$ROOT_DIR/scripts/resolve_simulator_destination.sh" ipad)"
fi

mkdir -p "$SCRATCH_ROOT"

echo "== regenerate Xcode projects =="
(
  cd "$ROOT_DIR/apps/ios/CodingOnTheGo"
  xcodegen generate
)
(
  cd "$ROOT_DIR/apps/macOS/CodingOnTheGoCompanion"
  xcodegen generate
)

for pkg in Packages/*/Package.swift; do
  dir="${pkg%/Package.swift}"
  name="${dir##*/}"
  echo "== swift test $name =="
  swift test --package-path "$dir" --scratch-path "$SCRATCH_ROOT/$name" --skip-update
done

echo "== iOS tests =="
xcodebuild \
  -project apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj \
  -scheme CodingOnTheGo \
  -skipPackageUpdates \
  -destination "$IOS_DESTINATION" \
  test

echo "== iPad layout and multiwindow tests =="
xcodebuild \
  -project apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj \
  -scheme "$IPAD_SCHEME" \
  -testPlan "$IPAD_LAYOUT_PLAN" \
  -skipPackageUpdates \
  -destination "$IPAD_DESTINATION" \
  test

echo "== macOS tests =="
xcodebuild \
  -project apps/macOS/CodingOnTheGoCompanion/CodingOnTheGoCompanion.xcodeproj \
  -scheme CodingOnTheGoCompanion \
  -skipPackageUpdates \
  -destination "$MAC_DESTINATION" \
  test

if [[ "$COTG_ENABLE_LOCALHOST_INTEGRATION" == "1" ]]; then
  echo "== localhost safe lane =="
  "$ROOT_DIR/scripts/verify_safe_lane_localhost.sh"

  echo "== localhost loopback listener =="
  "$ROOT_DIR/scripts/start_localhost_loopback_listener.sh"
  "$ROOT_DIR/scripts/stop_localhost_loopback_listener.sh"
else
  echo "== localhost integration skipped =="
fi
