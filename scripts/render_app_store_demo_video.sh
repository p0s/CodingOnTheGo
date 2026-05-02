#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_ROOT="$ROOT/marketing/app-store/screenshots"
OUTPUT_DIR="$ROOT/marketing/app-store/demo-video"
OUTPUT_FILE="$OUTPUT_DIR/CodingOnTheGo-review-demo.mp4"

mkdir -p "$OUTPUT_DIR"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required screenshot: $path"
    exit 1
  fi
}

IPHONE_1="$SCREENSHOT_ROOT/iphone/01-machine-directory.png"
IPHONE_2="$SCREENSHOT_ROOT/iphone/02-connection-health.png"
IPHONE_3="$SCREENSHOT_ROOT/iphone/03-live-session.png"
IPHONE_4="$SCREENSHOT_ROOT/iphone/04-workspace-review.png"
IPAD_1="$SCREENSHOT_ROOT/ipad/01-three-pane-directory.png"
IPAD_2="$SCREENSHOT_ROOT/ipad/03-live-session.png"

require_file "$IPHONE_1"
require_file "$IPHONE_2"
require_file "$IPHONE_3"
require_file "$IPHONE_4"
require_file "$IPAD_1"
require_file "$IPAD_2"

ffmpeg -y \
  -loop 1 -t 3 -i "$IPHONE_1" \
  -loop 1 -t 3 -i "$IPHONE_2" \
  -loop 1 -t 3 -i "$IPHONE_3" \
  -loop 1 -t 3 -i "$IPHONE_4" \
  -loop 1 -t 3 -i "$IPAD_1" \
  -loop 1 -t 3 -i "$IPAD_2" \
  -filter_complex "\
    [0:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v0];\
    [1:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v1];\
    [2:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v2];\
    [3:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v3];\
    [4:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v4];\
    [5:v]scale=1290:2796:force_original_aspect_ratio=decrease,pad=1290:2796:(ow-iw)/2:(oh-ih)/2,setsar=1[v5];\
    [v0][v1][v2][v3][v4][v5]concat=n=6:v=1:a=0,format=yuv420p[v]" \
  -map "[v]" \
  -r 30 \
  "$OUTPUT_FILE"

echo "Wrote demo video to $OUTPUT_FILE"
