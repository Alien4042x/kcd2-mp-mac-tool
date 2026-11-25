#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/kcdmp-launcher-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
python3 -m unittest discover -s "$source_dir/ci" -p 'test_prepare_candidate_relocation.py'
python3 -m unittest discover -s "$source_dir/ci" -p 'test_bridge_resources.py'
xcrun clang -Wall -Wextra -Werror "$source_dir/ci/test_dock_policy_gate.c" -o "$check_dir/dock-policy-gate"
"$check_dir/dock-policy-gate"
xcrun swiftc -parse-as-library "$source_dir/webview-bridge/OfficialClientUpdater.swift" "$source_dir/ci/test_client_updater.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/client-updater"
"$check_dir/client-updater"
xcrun swiftc -parse-as-library "$source_dir/webview-bridge/LoaderPlacement.swift" "$source_dir/ci/test_loader_placement.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/loader-placement"
"$check_dir/loader-placement"
xcrun swiftc "$source_dir/SavedServers.swift" "$source_dir/ci/test_saved_servers.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/saved-servers"
"$check_dir/saved-servers"
xcrun swiftc "$source_dir/WineInputReport.swift" "$source_dir/ci/test_wine_input_report.swift" \
  -module-cache-path "$check_dir/module-cache" -o "$check_dir/wine-input-report"
"$check_dir/wine-input-report"
plutil -lint "$source_dir/KCDMP Mac.xcodeproj/project.pbxproj" "$source_dir/KCDMP.entitlements"
zsh -n "$source_dir/build.command"
for script in audio-tools/build.sh ci/prepare-bridge-toolchain.sh webview-bridge/build-loader.sh webview-bridge/build-dock-policy.sh; do
  sh -n "$source_dir/$script"
done
zsh -n "$source_dir/webview-bridge/build.sh"
