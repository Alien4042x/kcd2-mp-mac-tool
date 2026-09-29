#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
project="$source_dir/KCDMP Mac.xcodeproj"
derived_data="$source_dir/.build"

xcodebuild -project "$project" -scheme 'KCDMP Mac' -configuration Release \
  -derivedDataPath "$derived_data" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${KCDMP_SIGNING_IDENTITY:--}" build

built_app="$derived_data/Build/Products/Release/KCDMP Mac.app"
output_app="$source_dir/KCDMP Mac.app"
rm -rf "$output_app"
ditto "$built_app" "$output_app"
print "Hotovo: $output_app"
