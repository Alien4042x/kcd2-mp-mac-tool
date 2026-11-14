#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$source_dir")
output=${1:?Pass the generated-resource output directory}
toolchain=${KCDMP_LLVM_MINGW:-}
if [ -z "$toolchain" ] && [ -f "$repo_dir/.build/bridge-toolchain.path" ]; then
  toolchain=$(cat "$repo_dir/.build/bridge-toolchain.path")
fi
compiler="$toolchain/bin/x86_64-w64-mingw32-clang++"
if [ ! -x "$compiler" ]; then
  echo 'Run sh ci/prepare-bridge-toolchain.sh before building in Xcode.' >&2
  exit 1
fi
python3 "$source_dir/fetch_deps.py" --verify
mkdir -p "$output"
sh "$source_dir/build-dock-policy.sh" "$output/libKcdMpDockPolicy.dylib"
python3 "$source_dir/generate_stubs.py" "$source_dir/.deps/WebView2.h" "$output/stubs.hpp"
"$compiler" -std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unknown-pragmas -static -shared \
  -I"$source_dir/.deps" -I"$output" "$source_dir/bridge.cpp" "$source_dir/bridge.def" \
  -lws2_32 -lole32 -luuid -luser32 -lcomctl32 -Wl,--no-insert-timestamp -o "$output/WebView2Loader.dll"
python3 "$repo_dir/ci/prepare_bridge_resources.py" --repository "$repo_dir" --output "$output/launcher-target.json" \
  --bridge "$output/WebView2Loader.dll"
