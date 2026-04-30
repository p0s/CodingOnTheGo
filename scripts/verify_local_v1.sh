#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "scripts/verify_local_v1.sh is deprecated; forwarding to scripts/verify_local_runtime_matrix.sh" >&2
exec "$ROOT_DIR/scripts/verify_local_runtime_matrix.sh" "$@"
