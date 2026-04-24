#!/usr/bin/env bash
set -Eeuo pipefail

need_xcodegen=0

while (($#)); do
  case "$1" in
    --with-xcodegen)
      need_xcodegen=1
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

select_ci_xcode() {
  local candidates=(
    /Applications/Xcode_26.4.app
    /Applications/Xcode_26.3.app
    /Applications/Xcode_26.2.app
    /Applications/Xcode_26.1.1.app
    /Applications/Xcode_26.1.app
    /Applications/Xcode_26.0.1.app
    /Applications/Xcode_26.0.app
    /Applications/Xcode.app
  )
  local selected_app=""

  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      selected_app="$candidate"
      break
    fi
  done

  if [[ -z "$selected_app" ]]; then
    echo "No suitable Xcode.app installation found under /Applications." >&2
    exit 1
  fi

  local developer_dir="$selected_app/Contents/Developer"
  export DEVELOPER_DIR="$developer_dir"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'DEVELOPER_DIR=%s\n' "$developer_dir" >>"$GITHUB_ENV"
  fi

  echo "Selected DEVELOPER_DIR=$developer_dir"
}

ensure_xcodegen() {
  if command -v xcodegen >/dev/null 2>&1; then
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "xcodegen is missing and Homebrew is unavailable." >&2
    exit 1
  fi

  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
}

select_ci_xcode

if ((need_xcodegen)); then
  ensure_xcodegen
fi

xcodebuild -version
swift --version
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen version
fi
