#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IPAD_WRAPPER="$ROOT_DIR/scripts/run_physical_ipad_test.sh"
COMBINED_TEST="${COTG_IPAD_PARITY_COMBINED_TEST:-CodingOnTheGoPadUITests/CodingOnTheGoUITests/testPhysicalRealHostIPadResumeSendAndRestoreAfterRelaunch}"

SEND_TEST="${COTG_IPAD_PARITY_SEND_TEST:-CodingOnTheGoPadUITests/CodingOnTheGoUITests/testPhysicalRealHostIPadResumeSendKeepsSameThread}"
RESTORE_TEST="${COTG_IPAD_PARITY_RESTORE_TEST:-CodingOnTheGoPadUITests/CodingOnTheGoUITests/testPhysicalRealHostIPadRelaunchRestoresSameThread}"

if [[ -n "$COMBINED_TEST" ]]; then
  exec bash "$IPAD_WRAPPER" "$COMBINED_TEST"
fi

THREAD_ID_PATH="${COTG_TEST_IPAD_PARITY_THREAD_ID_PATH:-/tmp/cotg_ipad_parity_thread_id.txt}"
SEND_LOG_PATH="${COTG_TEST_IPAD_PARITY_SEND_LOG_PATH:-/tmp/cotg_ipad_parity_send.log}"

rm -f "$THREAD_ID_PATH" "$SEND_LOG_PATH"
export COTG_TEST_IPAD_PARITY_THREAD_ID_PATH="$THREAD_ID_PATH"

bash "$IPAD_WRAPPER" "$SEND_TEST" | tee "$SEND_LOG_PATH"

THREAD_ID="${COTG_TEST_IPAD_PARITY_THREAD_ID:-}"
if [[ -z "$THREAD_ID" && -f "$THREAD_ID_PATH" ]]; then
  THREAD_ID="$(tr -d '\r\n' < "$THREAD_ID_PATH")"
fi
if [[ -z "$THREAD_ID" ]]; then
  THREAD_ID="$(sed -n 's/^COTG_IPAD_PARITY_THREAD_ID=//p' "$SEND_LOG_PATH" | tail -n 1)"
fi
if [[ -z "$THREAD_ID" ]]; then
  echo "Failed to resolve the iPad parity thread ID from $SEND_TEST" >&2
  exit 66
fi

printf '%s\n' "$THREAD_ID" > "$THREAD_ID_PATH"
export COTG_TEST_IPAD_PARITY_THREAD_ID="$THREAD_ID"

bash "$IPAD_WRAPPER" "$RESTORE_TEST"
