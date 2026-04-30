#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/scripts/resolve_test_ssh_host.sh"
HOST_FILE="${COTG_TEST_SSH_HOST_FILE:-/tmp/cotg_test_ssh_host.txt}"
EMBEDDED_TAILNET_AUTH_KEY_FILE="${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY_FILE:-/tmp/cotg_embedded_tailnet_auth_key.txt}"
GENERATED_AUTH_SOURCE="$ROOT_DIR/apps/ios/CodingOnTheGo/Tests/CodingOnTheGoUITests/EmbeddedTailnetAuthKey.swift"
PROJECT_PATH="$ROOT_DIR/apps/ios/CodingOnTheGo/CodingOnTheGo.xcodeproj"
SCHEME="${COTG_IOS_SCHEME:-CodingOnTheGo}"
DEVICE_ID="${COTG_DEVICE_ID:-}"
DERIVED_DATA_PATH="${COTG_PHYSICAL_DERIVED_DATA_PATH:-$ROOT_DIR/.build/physical-devices/real-host-$(date +%Y%m%d%H%M%S)}"
DEFAULT_TEST="CodingOnTheGoUITests/CodingOnTheGoUITests/testPhysicalRealHostBrowserShowsProjectsAndThreads"
TEST_IDENTIFIER="${1:-$DEFAULT_TEST}"
ROUTE_MODE="${2:-}"
MAX_ATTEMPTS="${COTG_PHYSICAL_TEST_MAX_ATTEMPTS:-3}"

cd "$ROOT_DIR"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Set COTG_DEVICE_ID to the connected iPhone device identifier before running this physical-device proof." >&2
  exit 2
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

swift_optional_string_literal() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    printf 'nil'
    return 0
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

load_repo_env_value() {
  local key="$1"
  local env_file="$ROOT_DIR/.env"
  [[ -f "$env_file" ]] || return 1

  local line
  line="$(grep -E "^${key}=" "$env_file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1

  local value="${line#*=}"
  value="${value%$'\r'}"
  case "$value" in
    \"*\")
      value="${value:1:${#value}-2}"
      ;;
    \'*\')
      value="${value:1:${#value}-2}"
      ;;
  esac

  [[ -n "${value// }" ]] || return 1
  printf '%s\n' "$value"
}

resolve_external_tailnet_dns_name() {
  local explicit_dns_name="${COTG_TEST_EXTERNAL_TAILNET_DNS_NAME:-}"
  if [[ -n "${explicit_dns_name// }" ]]; then
    printf '%s\n' "${explicit_dns_name%.}"
    return 0
  fi

  require_command tailscale
  require_command jq

  local discovered_dns_name
  discovered_dns_name="$(
    tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty'
  )"
  discovered_dns_name="${discovered_dns_name%.}"
  if [[ -z "${discovered_dns_name// }" ]]; then
    echo "Failed to resolve a real external tailnet DNS name from local Tailscale status." >&2
    exit 1
  fi

  printf '%s\n' "$discovered_dns_name"
}

require_honest_route_inputs() {
  case "$ROUTE_MODE" in
    externalTailnet|external)
      export COTG_TEST_EXTERNAL_TAILNET_DNS_NAME
      COTG_TEST_EXTERNAL_TAILNET_DNS_NAME="$(resolve_external_tailnet_dns_name)"
      ;;
    embeddedTailnet|embedded)
      if [[ -z "${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY:-}" ]]; then
        echo "Embedded tailnet mode requires COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY or $EMBEDDED_TAILNET_AUTH_KEY_FILE." >&2
        exit 1
      fi
      if [[ -z "${COTG_TEST_SSH_HOST_KEY:-}" ]]; then
        echo "Embedded tailnet mode requires COTG_TEST_SSH_HOST_KEY for truthful host-key verification." >&2
        exit 1
      fi
      ;;
  esac
}

run_network_hygiene_preflight() {
  local preflight_mode=""
  case "$ROUTE_MODE" in
    sameLAN|localLAN|bonjour|manualSSH|manual|ssh)
      preflight_mode="lan"
      ;;
    externalTailnet|external|embeddedTailnet|embedded)
      preflight_mode="tailnet"
      ;;
    *)
      return 0
      ;;
  esac

  "$ROOT_DIR/scripts/network_hygiene_preflight.sh" "$preflight_mode"
}

export COTG_TEST_SSH_HOST="$(refresh_test_ssh_host)"
export COTG_TEST_SSH_HOST_RESOLVED="$COTG_TEST_SSH_HOST"
export COTG_TEST_SSH_HOST_FILE="$HOST_FILE"
if [[ -n "$ROUTE_MODE" ]]; then
  export COTG_TEST_REAL_HOST_LAUNCH_PLAN="$ROUTE_MODE"
fi
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
if [[ -z "${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY:-}" ]]; then
  key_value="$(load_repo_env_value "TAILSCALE_KEY" || true)"
  if [[ "$key_value" == tskey-* ]]; then
    export COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY="$key_value"
  fi
fi
if [[ -z "${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY:-}" && -f "$EMBEDDED_TAILNET_AUTH_KEY_FILE" ]]; then
  key_value="$(tr -d '\r\n' < "$EMBEDDED_TAILNET_AUTH_KEY_FILE")"
  if [[ "$key_value" == tskey-* ]]; then
    export COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY="$key_value"
  fi
fi

require_honest_route_inputs
run_network_hygiene_preflight

cleanup() {
  cat > "$GENERATED_AUTH_SOURCE" <<'EOF'
enum UITestEmbeddedTailnetAuthKey {
    static let value: String? = nil
}

enum UITestExternalTailnetDNSName {
    static let value: String? = nil
}

enum UITestSSHHostOverride {
    static let value: String? = nil
}

enum UITestWorktreeFlowRepoPath {
    static let value: String? = nil
}
EOF
}
trap cleanup EXIT

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -destination "id=$DEVICE_ID"
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA_PATH"
)

if [[ -n "${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY:-}" || -n "${COTG_TEST_EXTERNAL_TAILNET_DNS_NAME:-}" || -n "${COTG_TEST_SSH_HOST:-}" || -n "${COTG_TEST_WORKTREE_FLOW_REPO_PATH:-}" ]]; then
  embedded_auth_key_literal="$(swift_optional_string_literal "${COTG_TEST_EMBEDDED_TAILNET_AUTH_KEY:-}")"
  external_tailnet_dns_literal="$(swift_optional_string_literal "${COTG_TEST_EXTERNAL_TAILNET_DNS_NAME:-}")"
  ssh_host_override_literal="$(swift_optional_string_literal "${COTG_TEST_SSH_HOST:-}")"
  worktree_flow_repo_path_literal="$(swift_optional_string_literal "${COTG_TEST_WORKTREE_FLOW_REPO_PATH:-}")"
  cat > "$GENERATED_AUTH_SOURCE" <<EOF
enum UITestEmbeddedTailnetAuthKey {
    static let value: String? = $embedded_auth_key_literal
}

enum UITestExternalTailnetDNSName {
    static let value: String? = $external_tailnet_dns_literal
}

enum UITestSSHHostOverride {
    static let value: String? = $ssh_host_override_literal
}

enum UITestWorktreeFlowRepoPath {
    static let value: String? = $worktree_flow_repo_path_literal
}
EOF
fi

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  echo "Physical test attempt $attempt/$MAX_ATTEMPTS: $TEST_IDENTIFIER"
  if xcodebuild \
    "${XCODEBUILD_ARGS[@]}" \
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
