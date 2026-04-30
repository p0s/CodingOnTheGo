#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH_ROOT="${SCRATCH_ROOT:-/tmp/cotg-github-hosted-ci-$(date +%Y%m%d%H%M%S)}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-/tmp/cotg-github-hosted-derived-$(date +%Y%m%d%H%M%S)}"
IOS_DESTINATION="${IOS_DESTINATION:-}"
MAC_DESTINATION="${MAC_DESTINATION:-platform=macOS}"
SIMULATOR_BOOT_SETTLE_SECONDS="${SIMULATOR_BOOT_SETTLE_SECONDS:-5}"
IOS_RESULT_BUNDLE_PATH="${IOS_RESULT_BUNDLE_PATH:-}"
HEAVY_IOS_RESULT_BUNDLE_PATH="${HEAVY_IOS_RESULT_BUNDLE_PATH:-}"
MACOS_RESULT_BUNDLE_PATH="${MACOS_RESULT_BUNDLE_PATH:-}"

run_packages_task=0
run_ios_task=0
run_macos_task=0
run_heavy_ios_task=0

IOS_CI_SCHEME="${IOS_CI_SCHEME:-CodingOnTheGoCI}"
IOS_HOSTED_SAFE_PLAN="${IOS_HOSTED_SAFE_PLAN:-HostedSafe}"
IOS_HOSTED_EXTENDED_PLAN="${IOS_HOSTED_EXTENDED_PLAN:-HostedExtended}"

usage() {
  cat <<'EOF'
Usage: scripts/verify_github_hosted_ci.sh [all|packages|ios|macos|heavy-ios]...

Defaults to: all
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

simulator_id_from_destination() {
  local destination="$1"

  if [[ "$destination" == id=* ]]; then
    printf '%s\n' "${destination#id=}"
    return 0
  fi

  return 1
}

prepare_simulator() {
  local destination="$1"
  local simulator_id

  if ! simulator_id="$(simulator_id_from_destination "$destination")"; then
    return 0
  fi

  xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$simulator_id" -b
  sleep "$SIMULATOR_BOOT_SETTLE_SECONDS"
}

reboot_simulator() {
  local destination="$1"
  local simulator_id

  if ! simulator_id="$(simulator_id_from_destination "$destination")"; then
    return 0
  fi

  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$simulator_id" -b
  sleep "$SIMULATOR_BOOT_SETTLE_SECONDS"
}

run_xcodebuild_test_with_retry() {
  local destination="$1"
  shift

  prepare_simulator "$destination"

  if xcodebuild "$@" test; then
    return 0
  fi

  local status=$?
  if [[ "$status" -ne 65 ]]; then
    return "$status"
  fi

  echo "xcodebuild exited 65 for $destination; rebooting simulator and retrying once..." >&2
  reboot_simulator "$destination"
  xcodebuild "$@" test
}

run_package_tests() {
  mkdir -p "$SCRATCH_ROOT"

  for pkg in "$ROOT_DIR"/Packages/*/Package.swift; do
    dir="${pkg%/Package.swift}"
    name="${dir##*/}"
    echo "== swift test $name =="
    swift test --package-path "$dir" --scratch-path "$SCRATCH_ROOT/$name" --skip-update
  done
}

run_ios_simulator_tests() {
  local destination="${IOS_DESTINATION:-$("$ROOT_DIR/scripts/resolve_simulator_destination.sh" iphone)}"

  mkdir -p "$DERIVED_DATA_ROOT"
  xcodebuild_args=(
    -project "$ROOT_DIR/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
    -scheme "$IOS_CI_SCHEME"
    -testPlan "$IOS_HOSTED_SAFE_PLAN"
    -skipPackageUpdates
    -destination "$destination"
    -derivedDataPath "$DERIVED_DATA_ROOT/ios"
  )
  if [[ -n "$IOS_RESULT_BUNDLE_PATH" ]]; then
    xcodebuild_args+=(-resultBundlePath "$IOS_RESULT_BUNDLE_PATH")
  fi

  echo "== iPhone simulator test plan $IOS_HOSTED_SAFE_PLAN on scheme $IOS_CI_SCHEME =="
  run_xcodebuild_test_with_retry "$destination" "${xcodebuild_args[@]}"
}

run_heavy_simulator_tests() {
  local ios_destination="${IOS_DESTINATION:-$("$ROOT_DIR/scripts/resolve_simulator_destination.sh" iphone)}"

  mkdir -p "$DERIVED_DATA_ROOT"

  xcodebuild_args=(
    -project "$ROOT_DIR/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
    -scheme "$IOS_CI_SCHEME"
    -testPlan "$IOS_HOSTED_EXTENDED_PLAN"
    -skipPackageUpdates
    -destination "$ios_destination"
    -derivedDataPath "$DERIVED_DATA_ROOT/ios-heavy"
  )
  if [[ -n "$HEAVY_IOS_RESULT_BUNDLE_PATH" ]]; then
    xcodebuild_args+=(-resultBundlePath "$HEAVY_IOS_RESULT_BUNDLE_PATH")
  fi

  echo "== iPhone simulator test plan $IOS_HOSTED_EXTENDED_PLAN on scheme $IOS_CI_SCHEME =="
  run_xcodebuild_test_with_retry "$ios_destination" "${xcodebuild_args[@]}"

}

run_macos_tests() {
  mkdir -p "$DERIVED_DATA_ROOT"
  local xcodebuild_args=(
    -project "$ROOT_DIR/apps/macOS/CodingOnTheGoCompanion/CodingOnTheGoCompanion.xcodeproj"
    -scheme CodingOnTheGoCompanion
    -skipPackageUpdates
    -destination "$MAC_DESTINATION"
    -derivedDataPath "$DERIVED_DATA_ROOT/macos"
  )
  if [[ -n "$MACOS_RESULT_BUNDLE_PATH" ]]; then
    xcodebuild_args+=(-resultBundlePath "$MACOS_RESULT_BUNDLE_PATH")
  fi

  echo "== macOS companion tests =="
  xcodebuild "${xcodebuild_args[@]}" test
}

if (($# == 0)); then
  run_packages_task=1
  run_ios_task=1
  run_macos_task=1
else
  for task in "$@"; do
    case "$task" in
      all)
        run_packages_task=1
        run_ios_task=1
        run_macos_task=1
        ;;
      packages)
        run_packages_task=1
        ;;
      ios)
        run_ios_task=1
        ;;
      macos)
        run_macos_task=1
        ;;
      heavy-ios)
        run_heavy_ios_task=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown task: $task" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
fi

cd "$ROOT_DIR"

require_command jq
require_command swift
require_command xcodebuild
require_command xcrun

export COTG_ENABLE_LOCALHOST_INTEGRATION=0
export COTG_ENABLE_KEYCHAIN_TESTS=0
unset COTG_TEST_EXTERNAL_TAILNET_DNS_NAME
unset COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY
unset COTG_TEST_SSH_HOST_KEY
unset COTG_TEST_SSH_RAW_KEY_PATH

if [[ "$run_packages_task" == "1" ]]; then
  run_package_tests
fi

if [[ "$run_ios_task" == "1" ]]; then
  run_ios_simulator_tests
fi

if [[ "$run_macos_task" == "1" ]]; then
  run_macos_tests
fi

if [[ "$run_heavy_ios_task" == "1" ]]; then
  run_heavy_simulator_tests
fi
