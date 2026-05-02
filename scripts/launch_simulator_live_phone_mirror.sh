#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_BUNDLE_ID="${COTG_SIM_MIRROR_BUNDLE_ID:-com.example.codingonthego.ios}"
DEFAULT_DEVICE_NAME="${COTG_SIM_MIRROR_DEVICE_NAME:-test-iphone}"
DEFAULT_SIMULATOR_NAME="${COTG_SIM_MIRROR_SIMULATOR_NAME:-iPhone 17 Pro}"
DEFAULT_ARTIFACT_ROOT="${COTG_SIM_MIRROR_ARTIFACT_ROOT:-$ROOT_DIR/.build/simulator-live-mirror}"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"

DEVICE_NAME="$DEFAULT_DEVICE_NAME"
DEVICE_ID="${COTG_DEVICE_ID:-}"
SIMULATOR_NAME="$DEFAULT_SIMULATOR_NAME"
SIMULATOR_ID="${COTG_SIMULATOR_ID:-}"
PHONE_METADATA_PATH=""
ARTIFACT_DIR="$DEFAULT_ARTIFACT_ROOT/$RUN_STAMP"
SCREENSHOT_PATH=""
LAUNCH_APP=1

RAW_KEY_PATH="${COTG_TEST_SSH_RAW_KEY_PATH:-/tmp/cotg_app_test_key.raw}"
RAW_KEY_BASE64="${COTG_TEST_SSH_RAW_KEY_BASE64:-}"
SSH_HOST_OVERRIDE="${COTG_SIM_MIRROR_SSH_HOST:-localhost}"
SSH_USER_OVERRIDE="${COTG_TEST_SSH_USER:-}"
POST_LAUNCH_DELAY="${COTG_SIM_MIRROR_POST_LAUNCH_DELAY:-3}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Mirror the normal installed app state from a connected iPhone into the iOS
simulator, rewrite the preferred route into a simulator-safe localhost SSH lane,
and optionally launch the simulator app against that mirrored snapshot.

Options:
  --device-name <name>       Connected iPhone device name to pull from (default: $DEFAULT_DEVICE_NAME)
  --device-id <id>           Connected iPhone UDID to pull from
  --phone-metadata <path>    Reuse a previously exported machine-directory.json instead of pulling from device
  --simulator-name <name>    Simulator name to target (default: $DEFAULT_SIMULATOR_NAME)
  --simulator-id <id>        Simulator UDID to target
  --artifact-dir <path>      Directory for exported and rewritten metadata
  --raw-key-path <path>      32-byte raw Ed25519 seed file for localhost simulator auth
  --raw-key-base64 <value>   Base64-encoded raw Ed25519 seed for localhost simulator auth
  --screenshot <path>        Capture a simulator screenshot after launch
  --no-launch                Only prepare the mirrored metadata; do not launch the app
  --help                     Show this help

Environment overrides:
  COTG_DEVICE_ID
  COTG_SIMULATOR_ID
  COTG_TEST_SSH_RAW_KEY_PATH
  COTG_TEST_SSH_RAW_KEY_BASE64
  COTG_TEST_SSH_USER
  COTG_SIM_MIRROR_SSH_HOST
  COTG_SIM_MIRROR_POST_LAUNCH_DELAY
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
    --phone-metadata)
      PHONE_METADATA_PATH="${2:?missing value for --phone-metadata}"
      shift 2
      ;;
    --simulator-name)
      SIMULATOR_NAME="${2:?missing value for --simulator-name}"
      shift 2
      ;;
    --simulator-id)
      SIMULATOR_ID="${2:?missing value for --simulator-id}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:?missing value for --artifact-dir}"
      shift 2
      ;;
    --raw-key-path)
      RAW_KEY_PATH="${2:?missing value for --raw-key-path}"
      shift 2
      ;;
    --raw-key-base64)
      RAW_KEY_BASE64="${2:?missing value for --raw-key-base64}"
      shift 2
      ;;
    --screenshot)
      SCREENSHOT_PATH="${2:?missing value for --screenshot}"
      shift 2
      ;;
    --no-launch)
      LAUNCH_APP=0
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
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

resolve_connected_device_id() {
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

resolve_simulator_id() {
  local name="$1"
  xcrun simctl list devices available -j | jq -r --arg name "$name" '
    .devices
    | to_entries[]
    | .value[]
    | select(.isAvailable == true and .name == $name)
    | .udid
  ' | head -n 1
}

copy_live_phone_metadata() {
  local device_id="$1"
  local destination="$2"

  xcrun devicectl device copy from \
    --device "$device_id" \
    --domain-type appDataContainer \
    --domain-identifier "$APP_BUNDLE_ID" \
    --source 'Library/Application Support/CodingOnTheGo/machine-directory.json' \
    --destination "$destination" >/dev/null
}

require_cmd jq
require_cmd xcrun

mkdir -p "$ARTIFACT_DIR"

if [[ -z "$PHONE_METADATA_PATH" ]]; then
  if [[ -z "$DEVICE_ID" ]]; then
    DEVICE_ID="$(resolve_connected_device_id "$DEVICE_NAME")"
  fi

  if [[ -z "$DEVICE_ID" ]]; then
    echo "Unable to resolve a connected iPhone named '$DEVICE_NAME'." >&2
    echo "Use --device-id or reuse an exported snapshot with --phone-metadata." >&2
    exit 1
  fi

  PHONE_METADATA_PATH="$ARTIFACT_DIR/phone-machine-directory.json"
  copy_live_phone_metadata "$DEVICE_ID" "$PHONE_METADATA_PATH"
else
  if [[ ! -f "$PHONE_METADATA_PATH" ]]; then
    echo "Missing phone metadata file: $PHONE_METADATA_PATH" >&2
    exit 1
  fi
fi

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(resolve_simulator_id "$SIMULATOR_NAME")"
fi

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "Unable to resolve an available simulator named '$SIMULATOR_NAME'." >&2
  echo "Use --simulator-id to target a specific booted device." >&2
  exit 1
fi

SIMULATOR_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$APP_BUNDLE_ID" data 2>/dev/null || true)"
if [[ -z "$SIMULATOR_CONTAINER" ]]; then
  echo "App '$APP_BUNDLE_ID' is not installed on simulator $SIMULATOR_ID." >&2
  exit 1
fi

if [[ -z "$RAW_KEY_BASE64" ]]; then
  if [[ ! -f "$RAW_KEY_PATH" ]]; then
    echo "Missing raw localhost SSH key seed: $RAW_KEY_PATH" >&2
    echo "Provide --raw-key-base64 or --raw-key-path with the 32-byte Ed25519 seed used by the simulator localhost tests." >&2
    exit 1
  fi
fi

PREFERRED_MACHINE_ID="$(jq -r '.preferences.preferredMachineID // .recentSessions[0].machineID // .machines[0].id // empty' "$PHONE_METADATA_PATH")"
if [[ -z "$PREFERRED_MACHINE_ID" ]]; then
  echo "Unable to determine a preferred machine from $PHONE_METADATA_PATH" >&2
  exit 1
fi

PREFERRED_ROUTE_ID="$(jq -r --arg machine_id "$PREFERRED_MACHINE_ID" '
  (.machines[] | select(.id == $machine_id) | (.preferredRouteID // .lastSuccessfulRouteID // .routes[0].id)) // empty
' "$PHONE_METADATA_PATH")"
if [[ -z "$PREFERRED_ROUTE_ID" ]]; then
  echo "Unable to determine a preferred route for machine $PREFERRED_MACHINE_ID" >&2
  exit 1
fi

TRUSTED_HOST_KEY="$(jq -r --arg machine_id "$PREFERRED_MACHINE_ID" --arg route_id "$PREFERRED_ROUTE_ID" '
  .machines[]
  | select(.id == $machine_id)
  | .routes[]
  | select(.id == $route_id)
  | .trustedOpenSSHPublicKey // empty
' "$PHONE_METADATA_PATH")"
if [[ -z "$TRUSTED_HOST_KEY" ]]; then
  echo "The preferred phone route does not contain a trusted SSH host key." >&2
  echo "Trust the Mac on the phone first, then rerun the mirror workflow." >&2
  exit 1
fi

if [[ -z "$SSH_USER_OVERRIDE" ]]; then
  SSH_USER_OVERRIDE="$(jq -r --arg machine_id "$PREFERRED_MACHINE_ID" --arg route_id "$PREFERRED_ROUTE_ID" '
    (
      .machines[]
      | select(.id == $machine_id)
      | .routes[]
      | select(.id == $route_id)
      | .usernameHint
    ) // (
      .machines[]
      | select(.id == $machine_id)
      | .lastKnownUser
    ) // (
      .machines[]
      | select(.id == $machine_id)
      | .credentialRef.username
    ) // empty
  ' "$PHONE_METADATA_PATH")"
fi

if [[ -z "$SSH_USER_OVERRIDE" ]]; then
  echo "Unable to determine an SSH username from $PHONE_METADATA_PATH" >&2
  echo "Set COTG_TEST_SSH_USER or pass a phone snapshot that already has a trusted login." >&2
  exit 1
fi

MIRROR_DIR="$SIMULATOR_CONTAINER/Library/Application Support/CodingOnTheGo/UITesting/live-phone-mirror"
SIMULATOR_METADATA_PATH="$MIRROR_DIR/machine-directory.json"
SIMULATOR_SYNC_PATH="$MIRROR_DIR/cotg-sync-mirror.json"
MANIFEST_PATH="$ARTIFACT_DIR/manifest.json"

mkdir -p "$MIRROR_DIR"

jq \
  --arg machine_id "$PREFERRED_MACHINE_ID" \
  --arg route_id "$PREFERRED_ROUTE_ID" \
  --arg host "$SSH_HOST_OVERRIDE" \
  --arg host_key "$TRUSTED_HOST_KEY" \
  --arg username "$SSH_USER_OVERRIDE" \
  '
  .preferences.preferredMachineID = $machine_id
  | .preferences.preferredProtocol = "stdio"
  | .preferences.preferredBootstrap = "standardSSH"
  | .machines |= map(
      if .id == $machine_id then
        .credentialRef = null
        | .lastKnownUser = $username
        | .preferredRouteID = $route_id
        | .lastSuccessfulRouteID = $route_id
        | .routes |= map(
            if .id == $route_id then
              .kind = "localLAN"
              | .label = "Simulator localhost mirror"
              | .hostname = $host
              | .ipAddress = null
              | .magicDNSName = null
              | .sshPort = 22
              | .requiresExternalApp = false
              | .publishedByCompanion = false
              | .isRecommended = true
              | .isUserPinned = true
              | .health = "healthy"
              | .trustState = "trusted"
              | .trustedOpenSSHPublicKey = $host_key
              | .usernameHint = $username
            else
              .isUserPinned = false
            end
          )
      else
        .
      end
    )
  | .recentSessions |= map(
      if .machineID == $machine_id then
        .routeID = $route_id
        | .lastKnownRouteKind = "localLAN"
        | .lastKnownBootstrap = "standardSSH"
        | .lastKnownProtocol = "stdio"
      else
        .
      end
    )
  ' "$PHONE_METADATA_PATH" > "$SIMULATOR_METADATA_PATH"

: > "$SIMULATOR_SYNC_PATH"

jq -n \
  --arg app_bundle_id "$APP_BUNDLE_ID" \
  --arg device_id "${DEVICE_ID:-}" \
  --arg phone_metadata_path "$PHONE_METADATA_PATH" \
  --arg simulator_id "$SIMULATOR_ID" \
  --arg simulator_container "$SIMULATOR_CONTAINER" \
  --arg simulator_metadata_path "$SIMULATOR_METADATA_PATH" \
  --arg simulator_sync_path "$SIMULATOR_SYNC_PATH" \
  --arg preferred_machine_id "$PREFERRED_MACHINE_ID" \
  --arg preferred_route_id "$PREFERRED_ROUTE_ID" \
  --arg ssh_host "$SSH_HOST_OVERRIDE" \
  --arg ssh_user "$SSH_USER_OVERRIDE" \
  '{
    appBundleID: $app_bundle_id,
    sourceDeviceID: ($device_id | select(length > 0)),
    phoneMetadataPath: $phone_metadata_path,
    simulatorID: $simulator_id,
    simulatorContainer: $simulator_container,
    simulatorMetadataPath: $simulator_metadata_path,
    simulatorSyncPath: $simulator_sync_path,
    preferredMachineID: $preferred_machine_id,
    preferredRouteID: $preferred_route_id,
    sshMirrorHost: $ssh_host,
    sshMirrorUser: $ssh_user
  }' > "$MANIFEST_PATH"

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  export SIMCTL_CHILD_UI_TESTING=1
  export SIMCTL_CHILD_COTG_METADATA_PATH="$SIMULATOR_METADATA_PATH"
  export SIMCTL_CHILD_COTG_SYNC_MIRROR_PATH="$SIMULATOR_SYNC_PATH"
  export SIMCTL_CHILD_COTG_TEST_SSH_HOST="$SSH_HOST_OVERRIDE"
  export SIMCTL_CHILD_COTG_TEST_SSH_USER="$SSH_USER_OVERRIDE"
  export SIMCTL_CHILD_COTG_TEST_SSH_HOST_KEY="$TRUSTED_HOST_KEY"
  export SIMCTL_CHILD_COTG_DISABLE_AUTO_UPGRADE=1

  if [[ -n "$RAW_KEY_BASE64" ]]; then
    export SIMCTL_CHILD_COTG_TEST_SSH_RAW_KEY_BASE64="$RAW_KEY_BASE64"
  else
    export SIMCTL_CHILD_COTG_TEST_SSH_RAW_KEY_PATH="$RAW_KEY_PATH"
  fi

  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$APP_BUNDLE_ID" >/dev/null
  sleep "$POST_LAUNCH_DELAY"

  unset SIMCTL_CHILD_UI_TESTING
  unset SIMCTL_CHILD_COTG_METADATA_PATH
  unset SIMCTL_CHILD_COTG_SYNC_MIRROR_PATH
  unset SIMCTL_CHILD_COTG_TEST_SSH_HOST
  unset SIMCTL_CHILD_COTG_TEST_SSH_USER
  unset SIMCTL_CHILD_COTG_TEST_SSH_HOST_KEY
  unset SIMCTL_CHILD_COTG_DISABLE_AUTO_UPGRADE
  if [[ -n "$RAW_KEY_BASE64" ]]; then
    unset SIMCTL_CHILD_COTG_TEST_SSH_RAW_KEY_BASE64
  else
    unset SIMCTL_CHILD_COTG_TEST_SSH_RAW_KEY_PATH
  fi

  if [[ -n "$SCREENSHOT_PATH" ]]; then
    mkdir -p "$(dirname "$SCREENSHOT_PATH")"
    xcrun simctl io "$SIMULATOR_ID" screenshot "$SCREENSHOT_PATH" >/dev/null
  fi
fi

cat <<EOF
Prepared simulator live-phone mirror.
phone metadata: $PHONE_METADATA_PATH
simulator metadata: $SIMULATOR_METADATA_PATH
manifest: $MANIFEST_PATH
simulator: $SIMULATOR_ID
mirror route: $SSH_USER_OVERRIDE@$SSH_HOST_OVERRIDE
launched app: $([[ "$LAUNCH_APP" -eq 1 ]] && printf 'yes' || printf 'no')
EOF

if [[ -n "$SCREENSHOT_PATH" ]]; then
  echo "screenshot: $SCREENSHOT_PATH"
fi
