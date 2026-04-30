#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/scripts/resolve_test_ssh_host.sh"
HOST_FILE="${COTG_TEST_SSH_HOST_FILE:-/tmp/cotg_test_ssh_host.txt}"
PROJECT_PATH="$ROOT_DIR/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
SCHEME="${COTG_IPAD_SCHEME:-CodingOnTheGoPad}"
DEVICE_ID="${COTG_IPAD_DEVICE_ID:-}"
DERIVED_DATA_PATH="${COTG_IPAD_DERIVED_DATA_PATH:-$ROOT_DIR/.build/physical-devices/ipad-$(date +%Y%m%d%H%M%S)}"
DEFAULT_TEST="CodingOnTheGoPadUITests/CodingOnTheGoUITests/testPhysicalRealHostIPadResumeSendAndRestoreAfterRelaunch"
TEST_IDENTIFIER="${1:-$DEFAULT_TEST}"
MAX_ATTEMPTS="${COTG_PHYSICAL_TEST_MAX_ATTEMPTS:-3}"

cd "$ROOT_DIR"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Set COTG_IPAD_DEVICE_ID to the connected iPad device identifier before running this physical-device proof." >&2
  exit 2
fi

export COTG_TEST_SSH_HOST="$(refresh_test_ssh_host)"
export COTG_TEST_SSH_HOST_RESOLVED="$COTG_TEST_SSH_HOST"
export COTG_TEST_SSH_HOST_FILE="$HOST_FILE"
if [[ -n "${COTG_TEST_IPAD_PARITY_THREAD_ID:-}" ]]; then
  export COTG_TEST_IPAD_PARITY_THREAD_ID
fi
if [[ -n "${COTG_TEST_CROSS_DEVICE_THREAD_ID:-}" ]]; then
  export COTG_TEST_CROSS_DEVICE_THREAD_ID
fi
if [[ -n "${COTG_TEST_CROSS_DEVICE_MARKER:-}" ]]; then
  export COTG_TEST_CROSS_DEVICE_MARKER
fi
printf '%s\n' "$COTG_TEST_SSH_HOST" > "$HOST_FILE"

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  echo "Physical iPad test attempt $attempt/$MAX_ATTEMPTS: $TEST_IDENTIFIER"
  if xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    test \
    "-only-testing:$TEST_IDENTIFIER"; then
    exit 0
  fi

  if (( attempt == MAX_ATTEMPTS )); then
    exit 65
  fi

  sleep 5
  ((attempt += 1))
done
