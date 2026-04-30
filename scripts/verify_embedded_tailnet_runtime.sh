#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NO_PROXY_DEFAULTS="localhost,127.0.0.1,::1,.local,10.,192.168.,172.16.,172.17.,172.18.,172.19.,172.20.,172.21.,172.22.,172.23.,172.24.,172.25.,172.26.,172.27.,172.28.,172.29.,172.30.,172.31.,.ts.net,100.64."
if [[ -n "${NO_PROXY:-}" ]]; then
  export NO_PROXY="${NO_PROXY},${NO_PROXY_DEFAULTS}"
else
  export NO_PROXY="${NO_PROXY_DEFAULTS}"
fi
export no_proxy="${NO_PROXY}"

"$SCRIPT_DIR/network_hygiene_preflight.sh" tailnet

resolve_tailscalekit_path() {
  if [[ -n "${COTG_TAILSCALEKIT_PACKAGE_PATH:-}" ]]; then
    printf '%s\n' "${COTG_TAILSCALEKIT_PACKAGE_PATH}"
    return 0
  fi

  if [[ -d "$REPO_ROOT/Vendor/TailscaleKit" ]]; then
    printf '%s\n' "$REPO_ROOT/Vendor/TailscaleKit"
    return 0
  fi

  if [[ -d "$REPO_ROOT/Vendor/tailscale/TailscaleKit" ]]; then
    printf '%s\n' "$REPO_ROOT/Vendor/tailscale/TailscaleKit"
    return 0
  fi

  return 1
}

if ! TAILSCALEKIT_PATH="$(resolve_tailscalekit_path)"; then
  echo "FAIL: embedded-tailnet runtime verification is blocked because no vendored TailscaleKit package was found." >&2
  echo "Set COTG_TAILSCALEKIT_PACKAGE_PATH or place the package at Vendor/TailscaleKit before retrying." >&2
  exit 2
fi

if [[ ! -f "$TAILSCALEKIT_PATH/Package.swift" ]]; then
  echo "FAIL: the vendored TailscaleKit path does not contain a Swift package: $TAILSCALEKIT_PATH" >&2
  exit 2
fi

printf '== embedded tailnet runtime verifier ==\n'
printf 'repo_root: %s\n' "$REPO_ROOT"
printf 'tailscalekit_path: %s\n' "$TAILSCALEKIT_PATH"

swift test --package-path "$REPO_ROOT/Packages/TailnetEmbedded"

cat <<EOF
Embedded-tailnet code-path verification passed:
- proxy/tailnet bypass hygiene is acceptable on this Mac
- the vendored native runtime package is discoverable by the build graph
- TailnetEmbedded package tests pass with the current checkout

Live traffic verification still requires:
1. a signed TailscaleKit/libtailscale runtime artifact in the vendored package
2. a real authenticated tailnet profile in the app runtime
3. a host reachable over the embedded tailnet with SSH/Codex available

If those external prerequisites are present, launch the iOS app and verify that the embedded route becomes traffic-ready and upgrades into the normal SSH bootstrap path instead of staying in "waiting for SOCKS5 bootstrap".
EOF
