#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
toolchain=${KCDMP_LLVM_MINGW:-"$source_dir/.build/llvm-mingw-20260908"}
if [ ! -x "$toolchain/bin/x86_64-w64-mingw32-clang++" ]; then
  if [ -n "${KCDMP_LLVM_MINGW:-}" ]; then
    echo 'The selected LLVM-MinGW compiler is missing.' >&2
    exit 1
  fi
  mkdir -p "$source_dir/.build"
  stage=$(mktemp -d "$source_dir/.build/llvm-mingw-download.XXXXXX")
  trap 'rm -rf "$stage"' EXIT HUP INT TERM
  curl --fail --location --retry 3 --silent --show-error \
    'https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-macos-universal.tar.xz' \
    --output "$stage/compiler.tar.xz"
  echo 'd1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149  '"$stage/compiler.tar.xz" | shasum -a 256 --check
  mkdir "$stage/toolchain"
  tar -xJf "$stage/compiler.tar.xz" -C "$stage/toolchain" --strip-components=1
  test -x "$stage/toolchain/bin/x86_64-w64-mingw32-clang++"
  mv "$stage/toolchain" "$toolchain"
fi
python3 "$source_dir/webview-bridge/fetch_deps.py"
mkdir -p "$source_dir/.build"
printf '%s\n' "$toolchain" > "$source_dir/.build/bridge-toolchain.path"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'KCDMP_LLVM_MINGW=%s\n' "$toolchain" >> "$GITHUB_ENV"
fi
