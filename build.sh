#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${1:-$source_dir/dist}"
build_dir="$source_dir/.build"
app="$output_dir/休眠哨兵.app"
swift_compiler="/Library/Developer/CommandLineTools/usr/bin/swiftc"
if [ ! -x "$swift_compiler" ]; then swift_compiler="$(xcrun --find swiftc)"; fi
architecture="$(uname -m)"
sdk_path="$(xcrun --show-sdk-path)"
mkdir -p "$build_dir/module-cache" "$build_dir/AppIcon.iconset" "$app/Contents/MacOS" "$app/Contents/Resources"
"$swift_compiler" -swift-version 5 -O -target "$architecture-apple-macosx13.0" -sdk "$sdk_path" \
  -module-cache-path "$build_dir/module-cache" \
  "$source_dir/PowerMonitor.swift" "$source_dir/SleepRecovery.swift" "$source_dir/RecoveryPresentation.swift" "$source_dir/App.swift" \
  -framework AppKit -framework UserNotifications -framework ServiceManagement \
  -o "$app/Contents/MacOS/SleepGuard"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
"$swift_compiler" -swift-version 5 -sdk "$sdk_path" -module-cache-path "$build_dir/module-cache" \
  "$source_dir/Icon.swift" -framework AppKit -o "$build_dir/create-icon"
"$build_dir/create-icon" "$build_dir/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$build_dir/icon.png" --out "$build_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$build_dir/icon.png" --out "$build_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
"$swift_compiler" -swift-version 5 -sdk "$sdk_path" -module-cache-path "$build_dir/module-cache" \
  "$source_dir/PackIcon.swift" -o "$build_dir/pack-icon"
"$build_dir/pack-icon" "$build_dir/AppIcon.iconset" "$app/Contents/Resources/AppIcon.icns"
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "构建完成：$app"
