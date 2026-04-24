#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEY_PATH="${1:-$HOME/.ssh/cotg_localhost_test_ed25519}"
KNOWN_HOSTS_PATH="${KNOWN_HOSTS_PATH:-}"
PID_FILE="${PID_FILE:-/tmp/cotg-localhost-listener.pid}"
OWNED_FILE="${OWNED_FILE:-${PID_FILE}.owned}"
SSH_HOST="${SSH_HOST:-localhost}"
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_TARGET="${SSH_TARGET:-$SSH_USER@$SSH_HOST}"
KNOWN_HOSTS_EPHEMERAL=0
NO_PROXY_DEFAULTS="localhost,127.0.0.1,::1,.local,10.,192.168.,172.16.,172.17.,172.18.,172.19.,172.20.,172.21.,172.22.,172.23.,172.24.,172.25.,172.26.,172.27.,172.28.,172.29.,172.30.,172.31.,.ts.net,100.64."
if [[ -n "${NO_PROXY:-}" ]]; then
  export NO_PROXY="${NO_PROXY},${NO_PROXY_DEFAULTS}"
else
  export NO_PROXY="${NO_PROXY_DEFAULTS}"
fi
export no_proxy="${NO_PROXY}"

"$ROOT_DIR/scripts/network_hygiene_preflight.sh" localhost

if [[ -z "$KNOWN_HOSTS_PATH" ]]; then
  KNOWN_HOSTS_PATH="$(mktemp /tmp/cotg_known_hosts.XXXXXX)"
  KNOWN_HOSTS_EPHEMERAL=1
else
  touch "$KNOWN_HOSTS_PATH"
fi

cleanup() {
  if [[ "$KNOWN_HOSTS_EPHEMERAL" -eq 1 ]]; then
    rm -f "$KNOWN_HOSTS_PATH"
  fi
}

trap cleanup EXIT

command -v ssh >/dev/null 2>&1 || { echo "Missing required command: ssh" >&2; exit 1; }
[[ -f "$KEY_PATH" ]] || { echo "Missing localhost SSH key: $KEY_PATH" >&2; exit 1; }

ssh -i "$KEY_PATH" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS_PATH" "$SSH_TARGET" \
  PID_FILE="$PID_FILE" OWNED_FILE="$OWNED_FILE" 'bash -s' <<'EOF'
set -Eeuo pipefail

if [[ -f "$PID_FILE" ]]; then
  should_kill="1"
  if [[ -f "$OWNED_FILE" ]]; then
    should_kill="$(cat "$OWNED_FILE")"
  fi
  if [[ "$should_kill" == "1" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi
rm -f "$OWNED_FILE"
EOF

echo "localhost loopback listener stopped"
