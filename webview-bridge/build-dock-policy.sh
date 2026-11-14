#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:?Pass the output dylib path}
mkdir -p "$(dirname -- "$output")"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -O2 -fobjc-arc -fblocks -dynamiclib \
  -Wall -Wextra -Werror "$source_dir/DockPolicy.m" -framework AppKit -framework CoreFoundation \
  -install_name '@rpath/libKcdMpDockPolicy.dylib' -o "$output"
