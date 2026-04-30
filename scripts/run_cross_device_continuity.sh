#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/scripts/resolve_test_ssh_host.sh"
HOST_FILE="${COTG_TEST_SSH_HOST_FILE:-/tmp/cotg_test_ssh_host.txt}"
PHONE_TEST="${COTG_PHONE_CONTINUITY_TEST:-CodingOnTheGoUITests/CodingOnTheGoUITests/testPhysicalRealHostPhoneSeedsCrossDeviceThreadForIPad}"
IPAD_TEST="${COTG_IPAD_CONTINUITY_TEST:-CodingOnTheGoPadUITests/CodingOnTheGoUITests/testPhysicalRealHostIPadRestoresCrossDeviceThreadSeededByIPhone}"
MARKER="${COTG_TEST_CROSS_DEVICE_MARKER:-cross-device-$(date +%s)}"

export COTG_TEST_CROSS_DEVICE_MARKER="$MARKER"

export COTG_TEST_SSH_HOST="$(refresh_test_ssh_host)"
export COTG_TEST_SSH_HOST_RESOLVED="$COTG_TEST_SSH_HOST"
export COTG_TEST_SSH_HOST_FILE="$HOST_FILE"
printf '%s\n' "$COTG_TEST_SSH_HOST" > "$HOST_FILE"

echo "Using cross-device continuity marker: $MARKER"
"$ROOT_DIR/scripts/run_physical_real_host_test.sh" "$PHONE_TEST"
"$ROOT_DIR/scripts/run_physical_ipad_test.sh" "$IPAD_TEST"
