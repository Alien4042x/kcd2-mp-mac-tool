#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/kcdmp-launcher-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
xcrun swiftc "$source_dir/SavedServers.swift" "$source_dir/ci/test_saved_servers.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/saved-servers"
"$check_dir/saved-servers"
xcrun swiftc "$source_dir/WineInputReport.swift" "$source_dir/ci/test_wine_input_report.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/wine-input-report"
"$check_dir/wine-input-report"
plutil -lint "$source_dir/KCDMP Mac.xcodeproj/project.pbxproj" "$source_dir/KCDMP.entitlements"
zsh -n "$source_dir/build.command"
sh -n "$source_dir/audio-tools/build.sh"
