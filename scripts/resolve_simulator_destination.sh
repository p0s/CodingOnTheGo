#!/usr/bin/env bash
set -Eeuo pipefail

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

pick_simulator_id() {
  local preferred_name="$1"
  local regex="$2"

  xcrun simctl list devices available -j | jq -r --arg preferred "$preferred_name" --arg regex "$regex" '
    [
      .devices
      | to_entries[]
      | .value[]
      | select(.isAvailable == true)
      | select(.name | test($regex))
    ]
    | (map(select(.name == $preferred)) + map(select(.name != $preferred)))
    | .[0].udid // empty
  '
}

require_command jq
require_command xcrun

device_family="${1:-iphone}"

case "$device_family" in
  iphone)
    preferred_name="${COTG_IOS_SIMULATOR_NAME:-iPhone 17 Pro}"
    regex="${COTG_IOS_SIMULATOR_REGEX:-^iPhone}"
    ;;
  ipad)
    preferred_name="${COTG_IPAD_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
    regex="${COTG_IPAD_SIMULATOR_REGEX:-^iPad}"
    ;;
  *)
    echo "Unknown simulator family: $device_family" >&2
    echo "Expected one of: iphone, ipad" >&2
    exit 1
    ;;
esac

simulator_id="$(pick_simulator_id "$preferred_name" "$regex")"

if [[ -z "$simulator_id" ]]; then
  echo "No available $device_family simulator found." >&2
  exit 1
fi

printf 'id=%s\n' "$simulator_id"
