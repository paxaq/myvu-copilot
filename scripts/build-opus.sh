#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Volumes/m500/Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Volumes/m500/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
opus_work="${MYVU_OPUS_BUILD_ROOT:-$repo_root/.build/opus-source}"
version=1.6.1
archive="$opus_work/opus-$version.tar.gz"
mkdir -p "$opus_work" "$repo_root/Vendor"
if [[ ! -f "$archive" ]]; then
  curl -fL "https://downloads.xiph.org/releases/opus/opus-$version.tar.gz" -o "$archive"
fi
printf '%s  %s\n' 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1 "$archive" | shasum -a 256 -c -
if [[ ! -d "$opus_work/opus-$version" ]]; then
  tar -xzf "$archive" -C "$opus_work"
fi
opus_src="$opus_work/opus-$version"
headers="$opus_work/headers"
mkdir -p "$headers"
cp "$opus_src"/include/opus*.h "$headers/"
cat > "$headers/module.modulemap" <<'MODULE'
module COpus {
  umbrella "."
  export *
}
MODULE
cp "$opus_src/COPYING" "$repo_root/Vendor/OPUS-LICENSE.txt"

build_slice() {
  local slice="$1" system="$2" sdk="$3" archs="$4" deployment="$5"
  cmake -S "$opus_src" -B "$opus_work/$slice" -G Ninja \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
    -DCMAKE_BUILD_TYPE=Release -DOPUS_BUILD_SHARED_LIBRARY=OFF \
    -DOPUS_DISABLE_INTRINSICS=ON -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  cmake --build "$opus_work/$slice" --parallel 8
}
build_slice iphoneos iOS iphoneos arm64 15.0
build_slice iphonesimulator iOS iphonesimulator 'arm64;x86_64' 15.0
build_slice macos Darwin macosx 'arm64;x86_64' 12.0

if [[ -e "$repo_root/Vendor/COpus.xcframework" ]]; then
  echo 'Vendor/COpus.xcframework already exists; move it aside before rebuilding.' >&2
  exit 1
fi
xcodebuild -create-xcframework \
  -library "$opus_work/iphoneos/libopus.a" -headers "$headers" \
  -library "$opus_work/iphonesimulator/libopus.a" -headers "$headers" \
  -library "$opus_work/macos/libopus.a" -headers "$headers" \
  -output "$repo_root/Vendor/COpus.xcframework"
