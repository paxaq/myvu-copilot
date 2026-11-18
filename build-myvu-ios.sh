#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Volumes/m500/Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Volumes/m500/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
default_build_root="$PWD/.build/MyvuDemo"
if [[ -d /Volumes/m500/Developer/MyvuDemo ]]; then
  default_build_root=/Volumes/m500/Developer/MyvuDemo
fi
build_root="${MYVU_BUILD_ROOT:-$default_build_root}"
mkdir -p "$build_root"

xcodebuild \
  -project Examples/MyvuDemo/MyvuDemo.xcodeproj \
  -scheme MyvuDemo \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$build_root/build-ios.log"

printf '\nUnsigned iPhone app: %s\n' "$build_root/DerivedData/Build/Products/Debug-iphoneos/MyvuDemo.app"
