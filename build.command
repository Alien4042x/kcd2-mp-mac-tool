#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
project="$source_dir/KCDMP Mac.xcodeproj"
derived_data="${KCDMP_DERIVED_DATA:-/private/tmp/kcdmp-mac-build-$(id -u)}"
signing_identity="${KCDMP_SIGNING_IDENTITY:--}"

xcodebuild -quiet -project "$project" -scheme 'KCDMP Mac' -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO build

built_app="$derived_data/Build/Products/Release/KCDMP Mac.app"
staged_app="$derived_data/Packaging/KCDMP Mac.app"
output_app="$source_dir/KCDMP Mac.app"
rm -rf "$staged_app"
mkdir -p "${staged_app:h}"
ditto "$built_app" "$staged_app"
if [[ "$signing_identity" == '-' ]]; then
  codesign --force --deep --sign - "$staged_app"
else
  codesign --force --deep --options runtime --timestamp \
    --sign "$signing_identity" "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"
rm -rf "$output_app"
ditto "$staged_app" "$output_app"
print "Hotovo: $output_app"
