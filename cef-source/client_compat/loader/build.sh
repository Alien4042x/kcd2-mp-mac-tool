#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
toolchain=${KCDMP_LLVM_MINGW:-$HOME/llvm-mingw}
mkdir -p "$root_dir/bin"
cc="$toolchain/bin/x86_64-w64-mingw32-clang"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -municode "$root_dir/loader.c" -lpsapi -o "$root_dir/bin/kcdmp_compat_loader.exe"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -municode "$root_dir/watcher.c" -o "$root_dir/bin/kcdmp_compat_watcher.exe"
printf '%s\n' "Built AMD64 loader and watcher."
