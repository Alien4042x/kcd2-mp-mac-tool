#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
repo_dir="${source_dir:h}"
deps="$source_dir/.deps"
output="${KCDMP_BRIDGE_BUILD_DIR:-$source_dir/.build}"
webview="$deps/webview-3ab4b5d722438fc8a13e6ca830c5e2372d19a01d"
compiler="${KCDMP_BRIDGE_CXX:-$(command -v x86_64-w64-mingw32-g++)}"
python3 "$source_dir/fetch_deps.py" --verify
for required in "$deps/WebView2.h" "$deps/json.hpp" "$webview/core/include/webview/webview.h"; do
  [[ -f "$required" ]] || { print -u2 "Missing pinned dependency: $required"; exit 2; }
done
mkdir -p "$output"
python3 "$source_dir/generate_stubs.py" "$deps/WebView2.h" "$output/stubs.hpp"
includes=(-I"$deps" -I"$output" -I"$webview/core/include" -I"$webview/compatibility/mingw/include")
"$compiler" -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unknown-pragmas -static -shared "${includes[@]}" "$source_dir/bridge.cpp" "$source_dir/bridge.def" \
  -lws2_32 -lole32 -luuid -luser32 -lcomctl32 -Wl,--no-insert-timestamp -o "$output/WebView2Loader.dll"
"$compiler" -std=c++17 -O2 -static "${includes[@]}" "$source_dir/probe.cpp" \
  -ladvapi32 -lole32 -lshell32 -lshlwapi -luser32 -lversion -Wl,--no-insert-timestamp -o "$output/bridge-probe.exe"
app="$output/KCD2MP Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sh "$source_dir/build-dock-policy.sh" "$app/Contents/Resources/libKcdMpDockPolicy.dylib"
xcrun swiftc -swift-version 5 -O -parse-as-library "$repo_dir/SteamProcess.swift" "$repo_dir/CEFClientTarget.swift" \
  "$source_dir/LoaderPlacement.swift" "$source_dir/OfficialClientUpdater.swift" "$source_dir/PackagedLauncher.swift" "$source_dir/NativeHost.swift" \
  -framework AppKit -framework WebKit -framework AVFoundation -framework Security -module-cache-path "$output/swift-cache" \
  -o "$app/Contents/MacOS/bridge-host"
xcrun swiftc -swift-version 5 -O -parse-as-library "$repo_dir/SteamProcess.swift" "$source_dir/GateProbe.swift" \
  -module-cache-path "$output/swift-cache" -o "$output/gate-probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kcdmp.webkitbridge.prototype</string>
<key>CFBundleName</key><string>KCD2MP Mac</string>
<key>CFBundleDisplayName</key><string>KCD2MP Mac</string>
<key>CFBundleExecutable</key><string>bridge-host</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>KCD:MP uses the microphone for in-game voice chat through Wine.</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
iconset="$output/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips --resampleHeightWidth "$size" "$size" "$repo_dir/Assets/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips --resampleHeightWidth "$double" "$double" "$repo_dir/Assets/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$app/Contents/Resources/AppIcon.icns"
codesign --force --entitlements "$repo_dir/KCDMP.entitlements" --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/bridge-host" --self-test
print "Built KCD2MP Mac and standalone bridge probe in $output"
