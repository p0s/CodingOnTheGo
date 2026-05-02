#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
SCHEME="CodingOnTheGo"

DEFAULT_DEVICE_NAME="${COTG_DEVICE_NAME:-test-iphone}"
DEFAULT_SCREENSHOT_TEST="CodingOnTheGoUITests/CodingOnTheGoUITests/testPhysicalInstalledAppLiveScreenshots"
DEFAULT_CODEX_SCREENSHOT_TEST="CodingOnTheGoUITests/CodingOnTheGoUITests/testPhysicalInstalledAppLiveCodexScreenshots"
DEFAULT_BROWSER_AUDIT_TEST="CodingOnTheGoUITests/CodingOnTheGoUITests/testPhysicalRealHostPhoneBrowserButtonsAndSheetActionsWork"
DEFAULT_DERIVED_ROOT="${COTG_PHYSICAL_SCREENSHOT_DERIVED_ROOT:-$ROOT_DIR/.build/physical-live-screens}"
DEFAULT_RESULT_ROOT="${COTG_PHYSICAL_SCREENSHOT_RESULT_ROOT:-$ROOT_DIR/.build/physical-live-screens}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"

DEVICE_NAME="$DEFAULT_DEVICE_NAME"
DEVICE_ID="${COTG_DEVICE_ID:-}"
DERIVED_DATA_PATH="${COTG_PHYSICAL_SCREENSHOT_DERIVED_DATA:-$DEFAULT_DERIVED_ROOT/$RUN_STAMP}"
RESULT_BUNDLE_PATH="${COTG_PHYSICAL_SCREENSHOT_RESULT_BUNDLE:-$DEFAULT_RESULT_ROOT/Test-CodingOnTheGo-$RUN_STAMP.xcresult}"
ATTACHMENTS_DIR="${COTG_PHYSICAL_SCREENSHOT_OUTPUT:-/tmp/cotg-live-phone-screens-$RUN_STAMP}"
WITH_BROWSER_AUDIT=0
RERUN_ARGS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Capture live-state screenshots from the normal installed CodingOnTheGo app on a
connected iPhone by running the checked-in physical XCTest proof lane and
exporting the resulting .xcresult attachments.

Options:
  --device-name <name>     Connected iPhone device name to target (default: $DEFAULT_DEVICE_NAME)
  --device-id <id>         Connected iPhone device identifier/UDID to target
  --derived-data <path>    DerivedData path for the xcodebuild run
  --result-bundle <path>   Output .xcresult bundle path (or bundle prefix when using --with-browser-audit)
  --output <path>          Directory where exported screenshot attachments land
  --with-browser-audit     Also run the live browser/button audit as a second proof pass
  --help                   Show this help

Environment overrides:
  COTG_DEVICE_NAME
  COTG_DEVICE_ID
  COTG_PHYSICAL_SCREENSHOT_DERIVED_DATA
  COTG_PHYSICAL_SCREENSHOT_RESULT_BUNDLE
  COTG_PHYSICAL_SCREENSHOT_OUTPUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-name)
      DEVICE_NAME="${2:?missing value for --device-name}"
      shift 2
      ;;
    --device-id)
      DEVICE_ID="${2:?missing value for --device-id}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:?missing value for --derived-data}"
      shift 2
      ;;
    --result-bundle)
      RESULT_BUNDLE_PATH="${2:?missing value for --result-bundle}"
      shift 2
      ;;
    --output)
      ATTACHMENTS_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    --with-browser-audit)
      WITH_BROWSER_AUDIT=1
      RERUN_ARGS=" --with-browser-audit"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_device_id() {
  local name="$1"
  xcrun xcdevice list | jq -r --arg name "$name" '
    map(
      select(
        (.simulator // false | not)
        and ((.available // false) or (.status == "available"))
        and .name == $name
      )
    )
    | first
    | .identifier // empty
  '
}

require_cmd jq
require_cmd xcodebuild
require_cmd xcrun

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(resolve_device_id "$DEVICE_NAME")"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "Unable to resolve a connected iPhone for device name '$DEVICE_NAME'." >&2
  echo "Use --device-id <udid> if the phone is connected under a different name." >&2
  exit 1
fi

mkdir -p "$(dirname "$DERIVED_DATA_PATH")" "$(dirname "$RESULT_BUNDLE_PATH")"
rm -rf "$RESULT_BUNDLE_PATH" "$ATTACHMENTS_DIR"

run_proof_test() {
  local test_name="$1"
  local label="$2"
  local result_bundle="$RESULT_BUNDLE_PATH"
  local export_dir="$ATTACHMENTS_DIR"
  local xcodebuild_log="${TMPDIR:-/tmp}/cotg-live-screens-$RUN_STAMP-$label-xcodebuild.log"

  if [[ "$WITH_BROWSER_AUDIT" -eq 1 ]]; then
    result_bundle="${RESULT_BUNDLE_PATH%.xcresult}-$label.xcresult"
    export_dir="$ATTACHMENTS_DIR/$label"
  fi

  rm -rf "$result_bundle" "$export_dir"
  mkdir -p "$export_dir"

  echo "Running live installed-app screenshot proof on device id: $DEVICE_ID"
  echo "DerivedData: $DERIVED_DATA_PATH"
  echo "Result bundle: $result_bundle"
  echo "Export dir: $export_dir"
  echo "xcodebuild log: $xcodebuild_log"
  echo "Test: $test_name"

  if ! COTG_UI_TEST_PROOF_SCREENSHOT_DIR="$export_dir" \
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$SCHEME" \
      -destination "id=$DEVICE_ID" \
      -configuration Debug \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -resultBundlePath "$result_bundle" \
      test \
      "-only-testing:$test_name" 2>&1 | tee "$xcodebuild_log"; then
    if grep -q "Developer App Certificate is not trusted" "$xcodebuild_log"; then
      cat >&2 <<EOF

Physical screenshot capture failed because the UI test runner is not trusted on the device.
On the connected iPhone, open:
  Settings -> General -> VPN & Device Management
Then trust the developer app certificate for this account, and rerun:
  ./scripts/capture_physical_live_screenshots.sh$RERUN_ARGS

Result bundle (partial): $result_bundle
xcodebuild log: $xcodebuild_log
EOF
    fi
    echo >&2
    echo "Physical screenshot proof failed for $test_name" >&2
    echo "Result bundle (partial): $result_bundle" >&2
    echo "xcodebuild log: $xcodebuild_log" >&2
    return 1
  fi

  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$export_dir"

  cat <<EOF

Live physical screenshot capture complete for $test_name
xcresult: $result_bundle
attachments: $export_dir
EOF
}

run_proof_test "$DEFAULT_SCREENSHOT_TEST" "live-connections"
run_proof_test "$DEFAULT_CODEX_SCREENSHOT_TEST" "live-codex"

if [[ "$WITH_BROWSER_AUDIT" -eq 1 ]]; then
  run_proof_test "$DEFAULT_BROWSER_AUDIT_TEST" "browser-audit"
fi

cat <<EOF

Finished physical screenshot proof runs.
attachments root: $ATTACHMENTS_DIR
tests:
  - $DEFAULT_SCREENSHOT_TEST
  - $DEFAULT_CODEX_SCREENSHOT_TEST
EOF

if [[ "$WITH_BROWSER_AUDIT" -eq 1 ]]; then
  echo "  - $DEFAULT_BROWSER_AUDIT_TEST"
fi
