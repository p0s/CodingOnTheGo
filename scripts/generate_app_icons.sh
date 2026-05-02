#!/bin/zsh
set -euo pipefail

repo_root="$(pwd)"
source_icon="$repo_root/marketing/app-store/icon/CodingOnTheGo-AppIcon-1024.png"

swift "$repo_root/scripts/generate_app_icons.swift" >/tmp/cotg-generate-icon-path.txt

mkdir -p \
  "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset" \
  "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset"

generate_png() {
  local size="$1"
  local destination="$2"
  sips -z "$size" "$size" "$source_icon" --out "$destination" >/dev/null
}

generate_png 40 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-20@2x.png"
generate_png 60 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-20@3x.png"
generate_png 58 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-29@2x.png"
generate_png 87 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-29@3x.png"
generate_png 80 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-40@2x.png"
generate_png 120 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-40@3x.png"
generate_png 120 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-60@2x.png"
generate_png 180 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-60@3x.png"
generate_png 76 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-76@1x.png"
generate_png 152 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-76@2x.png"
generate_png 167 "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-83.5@2x.png"
cp "$source_icon" "$repo_root/apps/ios/CodingOnTheGo/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"

generate_png 16 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16.png"
generate_png 32 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png"
generate_png 32 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png"
generate_png 64 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png"
generate_png 128 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png"
generate_png 256 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png"
generate_png 256 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png"
generate_png 512 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
generate_png 512 "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png"
cp "$source_icon" "$repo_root/apps/macOS/CodingOnTheGoCompanion/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
