#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
IPHONE_SCHEME="CodingOnTheGo"
IPHONE_BUNDLE_ID="com.example.codingonthego.ios"
IPAD_SCHEME="CodingOnTheGoPad"
IPAD_BUNDLE_ID="com.example.codingonthego.ipad"
OUTPUT_DIR="$ROOT/marketing/app-store/device-validation"
DERIVED_ROOT="$ROOT/.build/physical-devices"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
DERIVED_DIR="$DERIVED_ROOT/$RUN_STAMP"
TMP_DIR="$(mktemp -d /tmp/cotg-physical-XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$DERIVED_DIR"

XCODE_JSON="$TMP_DIR/xcdevice.json"
xcrun xcdevice list > "$XCODE_JSON"

device_id_for_name() {
  local device_name="$1"
  jq -r --arg device_name "$device_name" '
    .[]
    | select(.simulator == false and .platform == "com.apple.platform.iphoneos" and .name == $device_name)
    | .identifier
  ' "$XCODE_JSON" | head -n 1
}

build_and_install() {
  local label="$1"
  local device_name="$2"
  local identifier="$3"
  local scheme="$4"
  local bundle_id="$5"
  local slug="${label:l}"
  local derived="$DERIVED_DIR/$slug"
  local build_log="$OUTPUT_DIR/${slug}-build.log"
  local install_log="$OUTPUT_DIR/${slug}-install.log"

  echo "== Building for $label ($device_name / $identifier) =="
  if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "id=$identifier" \
    -configuration Debug \
    -derivedDataPath "$derived" \
    -allowProvisioningUpdates \
    build > "$build_log" 2>&1; then
    echo "Build failed for $label. Full log: $build_log"
    tail -n 80 "$build_log"
    return 1
  fi

  local app_path
  app_path="$(find "$derived/Build/Products/Debug-iphoneos" -maxdepth 1 -name '*.app' -print | head -n 1)"
  if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    echo "Built app missing for $label in $derived/Build/Products/Debug-iphoneos"
    return 1
  fi

  echo "== Installing on $label ($device_name) =="
  if ! xcrun devicectl device install app \
    --device "$identifier" \
    "$app_path" \
    --log-output "$install_log" > /dev/null 2>&1; then
    echo "Install failed for $label. Full log: $install_log"
    tail -n 80 "$install_log" 2>/dev/null || true
    return 1
  fi

  echo "== Launching on $label ($device_name) =="
  xcrun devicectl device process launch \
    --device "$identifier" \
    "$bundle_id" \
    --log-output "$OUTPUT_DIR/${slug}-launch.log" > /dev/null 2>&1 || true
}

IPHONE_NAME="${1:-test-iphone}"
IPAD_NAME="${2:-ppad}"

IPHONE_ID="$(device_id_for_name "$IPHONE_NAME")"
IPAD_ID="$(device_id_for_name "$IPAD_NAME")"

if [[ -z "$IPHONE_ID" ]]; then
  echo "Unable to find connected iPhone device named '$IPHONE_NAME'."
  exit 1
fi

if [[ -z "$IPAD_ID" ]]; then
  echo "Unable to find connected iPad device named '$IPAD_NAME'."
  exit 1
fi

build_and_install "iPhone" "$IPHONE_NAME" "$IPHONE_ID" "$IPHONE_SCHEME" "$IPHONE_BUNDLE_ID"
build_and_install "iPad" "$IPAD_NAME" "$IPAD_ID" "$IPAD_SCHEME" "$IPAD_BUNDLE_ID"

echo "Derived data kept at $DERIVED_DIR"
echo "Physical-device build/install validation completed."
