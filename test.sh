#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$source_dir/.build"
swift_compiler="/Library/Developer/CommandLineTools/usr/bin/swiftc"
if [ ! -x "$swift_compiler" ]; then swift_compiler="$(xcrun --find swiftc)"; fi
sdk_path="$(xcrun --show-sdk-path)"
mkdir -p "$build_dir/module-cache"
"$swift_compiler" -swift-version 5 -sdk "$sdk_path" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$build_dir/module-cache" \
  "$source_dir/PowerMonitor.swift" "$source_dir/PowerMonitorTests.swift" \
  -o "$build_dir/power-monitor-tests"
"$build_dir/power-monitor-tests"

"$swift_compiler" -swift-version 5 -sdk "$sdk_path" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$build_dir/module-cache" \
  "$source_dir/PowerMonitor.swift" "$source_dir/SleepRecovery.swift" \
  "$source_dir/RecoveryPresentation.swift" "$source_dir/SleepRecoveryTests.swift" \
  -o "$build_dir/sleep-recovery-tests"
"$build_dir/sleep-recovery-tests"
