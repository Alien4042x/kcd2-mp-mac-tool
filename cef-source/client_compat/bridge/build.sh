#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compiler=${KCDMP_LLVM_MINGW:-$HOME/llvm-mingw}/bin/x86_64-w64-mingw32-clang++
mkdir -p "$project_root/client_compat/bin"
"$compiler" -std=c++17 -O2 -static -shared -Wall -Wextra -Werror \
  "$project_root/client_compat/bridge/cef_compat.cpp" "$project_root/client_compat/bridge/cpu_bridge.cpp" \
  -ld3d12 -ldxguid -lbcrypt -o "$project_root/client_compat/bin/KcdMpCefCompat.dll"
