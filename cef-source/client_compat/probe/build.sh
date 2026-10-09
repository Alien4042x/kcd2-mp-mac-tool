#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$here/bin"
clang -std=c11 -O2 -Wall -Wextra -Werror \
  "$here/macos_ntdll_page_probe.c" -o "$here/bin/macos_ntdll_page_probe"
printf '%s\n' "$here/bin/macos_ntdll_page_probe"
