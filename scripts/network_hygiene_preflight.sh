#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-all}"
TAILNET_LOCAL_PROXY_BYPASS_CONFIRMED="${COTG_NETWORK_HYGIENE_TAILNET_LOCAL_PROXY_BYPASS_CONFIRMED:-0}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command scutil
require_command pgrep

SYSTEM_PROXY_OUTPUT="$(scutil --proxy 2>/dev/null || true)"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-}}"

env_proxy_keys=()
for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
  value="${!key:-}"
  if [[ -n "${value// }" ]]; then
    env_proxy_keys+=("$key")
  fi
done

system_proxy_enabled=0
for key in HTTPEnable HTTPSEnable SOCKSEnable ProxyAutoConfigEnable; do
  if printf '%s\n' "$SYSTEM_PROXY_OUTPUT" | grep -q "$key : 1"; then
    system_proxy_enabled=1
    break
  fi
done

shadowrocket_active=0
if pgrep -x a VPN or proxy app >/dev/null 2>&1 || pgrep -f a VPN or proxy app >/dev/null 2>&1; then
  shadowrocket_active=1
fi

contains_any() {
  local haystack="$1"
  shift
  local needle
  for needle in "$@"; do
    if [[ "$haystack" == *"$needle"* ]]; then
      return 0
    fi
  done
  return 1
}

system_local_bypass=0
if printf '%s\n' "$SYSTEM_PROXY_OUTPUT" | grep -q 'ExcludeSimpleHostnames : 1'; then
  system_local_bypass=1
fi
if printf '%s\n' "$SYSTEM_PROXY_OUTPUT" | grep -Eqi 'localhost|127\.0\.0\.1|::1'; then
  system_local_bypass=1
fi

system_lan_bypass=0
if (( system_local_bypass )); then
  system_lan_bypass=1
fi
if printf '%s\n' "$SYSTEM_PROXY_OUTPUT" | grep -Eqi '\.local|10\.|192\.168\.|172\.'; then
  system_lan_bypass=1
fi

system_tailnet_bypass=0
if printf '%s\n' "$SYSTEM_PROXY_OUTPUT" | grep -Eqi '\.ts\.net|100\.64\.'; then
  system_tailnet_bypass=1
fi

lower_no_proxy="$(printf '%s' "$NO_PROXY_VALUE" | tr '[:upper:]' '[:lower:]')"

env_local_bypass=0
if contains_any "$lower_no_proxy" "localhost" "127.0.0.1" "::1"; then
  env_local_bypass=1
fi

env_lan_bypass=0
if (( env_local_bypass )) && contains_any "$lower_no_proxy" ".local" "10." "192.168." "172.16." "172.17." "172.18." "172.19." "172.20." "172.21." "172.22." "172.23." "172.24." "172.25." "172.26." "172.27." "172.28." "172.29." "172.30." "172.31."; then
  env_lan_bypass=1
fi

env_tailnet_bypass=0
if contains_any "$lower_no_proxy" ".ts.net" "ts.net" "100.64."; then
  env_tailnet_bypass=1
fi

tailnet_local_proxy_bypass_override=0
if [[ "$TAILNET_LOCAL_PROXY_BYPASS_CONFIRMED" == "1" ]]; then
  tailnet_local_proxy_bypass_override=1
fi

proxy_active=0
if (( system_proxy_enabled )) || (( ${#env_proxy_keys[@]} > 0 )) || (( shadowrocket_active )); then
  proxy_active=1
fi

localhost_risk=0
lan_risk=0
tailnet_risk=0
if (( proxy_active )) && ! (( system_local_bypass || env_local_bypass )); then
  localhost_risk=1
fi
if (( proxy_active )) && ! (( system_lan_bypass || env_lan_bypass )); then
  lan_risk=1
fi
if (( proxy_active )) && ! (( system_tailnet_bypass || env_tailnet_bypass )); then
  tailnet_risk=1
fi
if (( tailnet_risk )) && (( tailnet_local_proxy_bypass_override )); then
  tailnet_risk=0
fi

printf '== network hygiene preflight ==\n'
printf 'mode: %s\n' "$MODE"
printf 'system_proxy_enabled: %s\n' "$system_proxy_enabled"
printf 'shadowrocket_active: %s\n' "$shadowrocket_active"
printf 'env_proxy_keys: %s\n' "${env_proxy_keys[*]:-none}"
printf 'localhost_bypass: system=%s env=%s\n' "$system_local_bypass" "$env_local_bypass"
printf 'lan_bypass: system=%s env=%s\n' "$system_lan_bypass" "$env_lan_bypass"
printf 'tailnet_bypass: system=%s env=%s\n' "$system_tailnet_bypass" "$env_tailnet_bypass"
printf 'tailnet_local_proxy_bypass_override: %s\n' "$tailnet_local_proxy_bypass_override"

if [[ -n "$NO_PROXY_VALUE" ]]; then
  printf 'no_proxy: %s\n' "$NO_PROXY_VALUE"
else
  printf 'no_proxy: unset\n'
fi

if [[ -n "$SYSTEM_PROXY_OUTPUT" ]]; then
  printf '\n-- scutil --proxy --\n%s\n' "$SYSTEM_PROXY_OUTPUT"
fi

if (( tailnet_local_proxy_bypass_override )) && ! (( system_tailnet_bypass || env_tailnet_bypass )); then
  printf '\nNOTE: tailnet bypass is not visible in system proxy or NO_PROXY settings; relying on COTG_NETWORK_HYGIENE_TAILNET_LOCAL_PROXY_BYPASS_CONFIRMED=1 for an operator-confirmed local proxy-app bypass.\n'
fi

case "$MODE" in
  localhost)
    if (( localhost_risk )); then
      echo "FAIL: active proxy or third-party VPN/proxy state is present without an explicit localhost bypass. Add localhost,127.0.0.1,::1 to NO_PROXY and bypass local traffic in the proxy app before running localhost verification." >&2
      exit 2
    fi
    ;;
  lan)
    if (( lan_risk )); then
      echo "FAIL: active proxy or third-party VPN/proxy state is present without a LAN bypass. Bypass .local and RFC1918 private-network traffic before running LAN discovery or reachability verification." >&2
      exit 2
    fi
    ;;
  tailnet)
    if (( tailnet_risk )); then
      echo "FAIL: active proxy or third-party VPN/proxy state is present without a tailnet bypass. Bypass 100.64.0.0/10 and *.ts.net traffic before running embedded or external tailnet verification." >&2
      exit 2
    fi
    ;;
  all)
    if (( localhost_risk || lan_risk || tailnet_risk )); then
      echo "FAIL: proxy/VPN state is likely to taint localhost, LAN, or tailnet verification. Add direct bypass rules for localhost, .local, RFC1918 private ranges, 100.64.0.0/10, and *.ts.net before retrying." >&2
      exit 2
    fi
    ;;
  *)
    echo "Unknown preflight mode: $MODE" >&2
    exit 1
    ;;
esac

echo "network hygiene preflight passed"
