#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compiler=${KCDMP_LLVM_MINGW:-$HOME/llvm-mingw}/bin/x86_64-w64-mingw32-clang++
if [ "${KCDMP_REGENERATE_TARGET:-0}" = 1 ]; then
  python3 "$project_root/client_compat/bridge/inspect_target.py"
fi
mkdir -p "$project_root/client_compat/bin"
"$compiler" -std=c++17 -O2 -static -shared -Wall -Wextra -Werror \
  "$project_root/client_compat/bridge/cef_compat.cpp" "$project_root/client_compat/bridge/cpu_bridge.cpp" \
  -ld3d12 -ldxguid -lbcrypt -o "$project_root/client_compat/bin/KcdMpCefCompat.dll"
