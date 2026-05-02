#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repo_root/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
iphone_scheme="CodingOnTheGo"
ipad_scheme="CodingOnTheGoPad"
iphone_output="$repo_root/marketing/app-store/screenshots/iphone"
ipad_output="$repo_root/marketing/app-store/screenshots/ipad"
capture_marker="$repo_root/marketing/app-store/screenshots/.capture-request"
cleanup_script="$repo_root/scripts/clean_legacy_ios_bundle_ids.sh"
iphone_destination="${COTG_SCREENSHOT_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro}"
ipad_destination="${COTG_SCREENSHOT_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4)}"

mkdir -p "$iphone_output" "$ipad_output"
touch "$capture_marker"
trap 'rm -f "$capture_marker"' EXIT

if [[ -n "${COTG_SCREENSHOT_IPHONE_SIMULATOR_ID:-}" ]]; then
  "$cleanup_script" "$COTG_SCREENSHOT_IPHONE_SIMULATOR_ID"
fi
if [[ -n "${COTG_SCREENSHOT_IPAD_SIMULATOR_ID:-}" ]]; then
  "$cleanup_script" "$COTG_SCREENSHOT_IPAD_SIMULATOR_ID"
fi

xcodebuild \
  -project "$project_path" \
  -scheme "$iphone_scheme" \
  -destination "$iphone_destination" \
  -only-testing:CodingOnTheGoUITests/CodingOnTheGoUITests/testCaptureIPhoneAppStoreScreenshots \
  test

xcodebuild \
  -project "$project_path" \
  -scheme "$ipad_scheme" \
  -destination "$ipad_destination" \
  -only-testing:CodingOnTheGoPadUITests/CodingOnTheGoUITests/testCaptureIPadAppStoreScreenshots \
  test
