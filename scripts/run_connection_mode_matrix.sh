#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PHONE_WRAPPER="$ROOT_DIR/scripts/run_physical_real_host_test.sh"

TESTS=(
  "CodingOnTheGoUITests/CodingOnTheGoUITests/testSeededLocalhostLANRouteConnectsThroughDiscoveredBonjourRoute"
  "CodingOnTheGoUITests/CodingOnTheGoUITests/testSeededLocalhostManualRouteConnectsThroughConfiguredSSHOverride"
  "CodingOnTheGoUITests/CodingOnTheGoUITests/testSeededExternalTailnetRouteConnectsThroughStandaloneTailscale"
  "CodingOnTheGoUITests/CodingOnTheGoUITests/testSeededEmbeddedTailnetRouteConnectsThroughInAppTailscale"
)

for test_identifier in "${TESTS[@]}"; do
  echo "== Route matrix: $test_identifier =="
  bash "$PHONE_WRAPPER" "$test_identifier"
done
