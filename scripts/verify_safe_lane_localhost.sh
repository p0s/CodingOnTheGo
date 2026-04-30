#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEY_PATH="${1:-$HOME/.ssh/cotg_localhost_test_ed25519}"
KNOWN_HOSTS_PATH="${KNOWN_HOSTS_PATH:-}"
WORKDIR="${WORKDIR:-$ROOT_DIR}"
REMOTE_CODEX_HOME="${REMOTE_CODEX_HOME:-}"
SSH_HOST="${SSH_HOST:-localhost}"
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_TARGET="${SSH_TARGET:-$SSH_USER@$SSH_HOST}"
KNOWN_HOSTS_EPHEMERAL=0
if [[ -z "$KNOWN_HOSTS_PATH" ]]; then
  KNOWN_HOSTS_PATH="$(mktemp /tmp/cotg_known_hosts.XXXXXX)"
  KNOWN_HOSTS_EPHEMERAL=1
else
  touch "$KNOWN_HOSTS_PATH"
fi
REMOTE_COMMAND=$'set -Eeuo pipefail\nCODEX_HOME_PATH="${REMOTE_CODEX_HOME:-$HOME/.codex}"\nif [[ -n "${REMOTE_CODEX_HOME:-}" ]]; then\n  ORIGINAL_HOME="$HOME"\n  REMOTE_HOME="$(dirname "$CODEX_HOME_PATH")"\n  mkdir -p "$REMOTE_HOME" "$CODEX_HOME_PATH"\n  if [[ -f "$ORIGINAL_HOME/.codex/auth.json" ]] && [[ ! -f "$CODEX_HOME_PATH/auth.json" ]]; then\n    cp "$ORIGINAL_HOME/.codex/auth.json" "$CODEX_HOME_PATH/auth.json"\n  fi\n  exec env HOME="$REMOTE_HOME" PATH=/opt/homebrew/bin:/usr/local/bin:$PATH CODEX_HOME="$CODEX_HOME_PATH" codex app-server --listen stdio://\nelse\n  mkdir -p "$CODEX_HOME_PATH"\n  exec env PATH=/opt/homebrew/bin:/usr/local/bin:$PATH codex app-server --listen stdio://\nfi'

NO_PROXY_DEFAULTS="localhost,127.0.0.1,::1,.local,10.,192.168.,172.16.,172.17.,172.18.,172.19.,172.20.,172.21.,172.22.,172.23.,172.24.,172.25.,172.26.,172.27.,172.28.,172.29.,172.30.,172.31.,.ts.net,100.64."
if [[ -n "${NO_PROXY:-}" ]]; then
  export NO_PROXY="${NO_PROXY},${NO_PROXY_DEFAULTS}"
else
  export NO_PROXY="${NO_PROXY_DEFAULTS}"
fi
export no_proxy="${NO_PROXY}"

"$ROOT_DIR/scripts/network_hygiene_preflight.sh" localhost

PIPE_DIR="$(mktemp -d)"
INPUT_PIPE="$PIPE_DIR/input.pipe"
OUTPUT_PIPE="$PIPE_DIR/output.pipe"
mkfifo "$INPUT_PIPE" "$OUTPUT_PIPE"

command -v jq >/dev/null 2>&1 || { echo "Missing required command: jq" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "Missing required command: ssh" >&2; exit 1; }
[[ -f "$KEY_PATH" ]] || { echo "Missing localhost SSH key: $KEY_PATH" >&2; exit 1; }

ssh \
  -i "$KEY_PATH" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_PATH" \
  "$SSH_TARGET" \
  'env PATH=/opt/homebrew/bin:/usr/local/bin:$PATH command -v codex >/dev/null 2>&1' >/dev/null

cleanup() {
  kill "${APP_PID:-0}" >/dev/null 2>&1 || true
  rm -rf "$PIPE_DIR"
  if [[ "$KNOWN_HOSTS_EPHEMERAL" -eq 1 ]]; then
    rm -f "$KNOWN_HOSTS_PATH"
  fi
}

trap cleanup EXIT

printf -v REMOTE_CODEX_HOME_ESCAPED '%q' "$REMOTE_CODEX_HOME"
printf -v REMOTE_COMMAND_ESCAPED '%q' "$REMOTE_COMMAND"

ssh \
  -i "$KEY_PATH" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_PATH" \
  "$SSH_TARGET" \
  "REMOTE_CODEX_HOME=$REMOTE_CODEX_HOME_ESCAPED bash -lc $REMOTE_COMMAND_ESCAPED" <"$INPUT_PIPE" >"$OUTPUT_PIPE" &
APP_PID=$!

sleep 1

exec 3>"$INPUT_PIPE"
exec 4<"$OUTPUT_PIPE"

send_json() {
  printf '%s\n' "$1" >&3
}

read_until_match() {
  local jq_expr="$1"
  local timeout_seconds="${2:-30}"
  local deadline=$((SECONDS + timeout_seconds))
  local line

  while (( SECONDS < deadline )); do
    IFS= read -r line <&4 || return 1
    printf '%s\n' "$line" >&2
    if printf '%s' "$line" | jq -e "$jq_expr" >/dev/null 2>&1; then
      printf '%s\n' "$line"
      return 0
    fi
  done

  return 1
}

send_json '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cotg-safe-lane","version":"0.1"}}}'
initialize_line="$(read_until_match '.id == 1' 15)"
send_json '{"method":"initialized","params":{}}'

send_json "$(jq -nc --arg cwd "$WORKDIR" '{id: 2, method: "thread/start", params: {cwd: $cwd}}')"
thread_line="$(read_until_match '.id == 2 and .result.thread.id' 20)"
thread_id="$(printf '%s' "$thread_line" | jq -r '.result.thread.id')"

send_json "$(jq -nc --arg tid "$thread_id" --arg text 'Reply with COTG_OK only.' '{id: 3, method: "turn/start", params: {threadId: $tid, input: [{type: "text", text: $text}]}}')"

turn_start_line="$(read_until_match '.id == 3 or .method == "turn/started" or (.method == "error" and ((.params.willRetry // false) | not))' 30 || true)"
turn_complete_line="$(read_until_match '.method == "turn/completed" or (.method == "error" and ((.params.willRetry // false) | not))' 180 || true)"

printf '\n=== SAFE LANE SUMMARY ===\n'
printf 'initialize: %s\n' "$initialize_line"
printf 'thread: %s\n' "$thread_line"
printf 'turn_start: %s\n' "${turn_start_line:-MISSING}"
printf 'turn_complete: %s\n' "${turn_complete_line:-MISSING}"
