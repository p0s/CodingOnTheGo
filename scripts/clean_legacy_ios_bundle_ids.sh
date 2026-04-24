#!/bin/zsh

set -euo pipefail

LEGACY_BUNDLE_IDS=(
  "com.example.CodingOnTheGo.ios"
  "CodingOnTheGo"
  "com.example.codingonthego.iosCodingOnTheGo"
)

target_mode="simulator"
target_identifier=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      target_mode="device"
      target_identifier="${2:-}"
      shift 2
      ;;
    --simulator)
      target_mode="simulator"
      target_identifier="${2:-}"
      shift 2
      ;;
    *)
      if [[ -z "$target_identifier" ]]; then
        target_identifier="$1"
      else
        echo "Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$target_mode" == "simulator" ]]; then
  target_udid="$target_identifier"

  if [[ -z "$target_udid" ]]; then
    target_udid="$(xcrun simctl list devices booted --json | jq -r '.devices[][] | .udid' | head -n 1)"
  fi

  if [[ -z "$target_udid" ]]; then
    echo "No booted simulator found. Pass a simulator UDID explicitly, or use --device <name>."
    exit 1
  fi

  echo "Cleaning legacy bundle IDs from simulator: $target_udid"

  xcrun simctl boot "$target_udid" > /dev/null 2>&1 || true
  xcrun simctl bootstatus "$target_udid" -b > /dev/null

  for bundle_id in "${LEGACY_BUNDLE_IDS[@]}"; do
    xcrun simctl uninstall "$target_udid" "$bundle_id" > /dev/null 2>&1 || true
    echo "Removed if present: $bundle_id"
  done

  echo "Legacy simulator bundle-id cleanup completed."
else
  target_device="$target_identifier"

  if [[ -z "$target_device" ]]; then
    echo "Pass a physical device name or UDID with --device <name>."
    exit 1
  fi

  echo "Cleaning legacy bundle IDs from physical device: $target_device"

  for bundle_id in "${LEGACY_BUNDLE_IDS[@]}"; do
    xcrun devicectl device uninstall app --device "$target_device" "$bundle_id" > /dev/null 2>&1 || true
    echo "Removed if present: $bundle_id"
  done

  echo "Legacy physical-device bundle-id cleanup completed."
fi
