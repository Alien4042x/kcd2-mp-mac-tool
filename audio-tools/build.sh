#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
compiler=${KCDMP_LLVM_MINGW:-$HOME/llvm-mingw}/bin/x86_64-w64-mingw32-clang
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -static \
  "$source_dir/microphone_probe.c" -lwinmm -o "$source_dir/microphone_probe.exe"
