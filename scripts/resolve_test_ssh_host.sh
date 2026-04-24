#!/usr/bin/env bash
set -Eeuo pipefail

refresh_test_ssh_host() {
  if [[ "${COTG_TEST_SSH_HOST_USE_EXISTING:-0}" == "1" ]] && [[ -n "${COTG_TEST_SSH_HOST:-}" ]]; then
    printf '%s\n' "$COTG_TEST_SSH_HOST"
    return 0
  fi

  dynamic_test_ssh_host
}

resolve_test_ssh_host() {
  if [[ -n "${COTG_TEST_SSH_HOST:-}" ]]; then
    printf '%s\n' "$COTG_TEST_SSH_HOST"
    return 0
  fi

  dynamic_test_ssh_host
}

dynamic_test_ssh_host() {
  local candidate=""
  for iface in en0 en1 bridge0; do
    candidate="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}
