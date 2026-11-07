#!/usr/bin/env bash
# Build the release-only static XCFramework on macOS.
# Slices: ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64.
# Headers live at Headers/LimLinkCoreFFI/ in every slice (not Headers/ root).
# Deployment: iOS 17.0, macOS 14.0. The archive must not contain llct_*.
#
# This script is shellchecked on Linux. It does not run there: Xcode, lipo,
# and `swift package compute-checksum` are on the macOS release job.
# Usage: ./scripts/package_apple.sh --zip /tmp/out
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

zip_dir=""
if [[ "${1:-}" == "--zip" ]]; then
  zip_dir="${2:?--zip needs a directory}"
  shift 2
fi
if [[ $# -ne 0 ]]; then
  echo "unknown argument: $1" >&2
  exit 2
fi
if [[ -z "$zip_dir" ]]; then
  echo "package_apple.sh requires --zip DIR" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package_apple.sh must run on macOS (Xcode lipo / xcodebuild / swift)" >&2
  exit 1
fi

export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

targets=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
  aarch64-apple-darwin
  x86_64-apple-darwin
)
for triple in "${targets[@]}"; do
  cargo build --release -p limlink-core --target "$triple"
done

stage="$root/target/xcframework-stage"
rm -rf "$stage"
mkdir -p "$stage/ios" "$stage/sim" "$stage/mac" "$stage/headers"

lib() {
  local triple="$1"
  printf '%s\n' "$root/target/$triple/release/liblimlink_core.a"
}

lipo -create "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)" \
  -output "$stage/sim/liblimlink_core.a"
cp "$(lib aarch64-apple-ios)" "$stage/ios/liblimlink_core.a"
lipo -create "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)" \
  -output "$stage/mac/liblimlink_core.a"

# Nested under LimLinkCoreFFI so the copied slice layout is
# Headers/LimLinkCoreFFI/, not a top-level Headers/module.modulemap.
mkdir -p "$stage/headers/LimLinkCoreFFI"
cp "$root/include/limlink_core.h" "$stage/headers/LimLinkCoreFFI/limlink_core.h"
cat >"$stage/headers/LimLinkCoreFFI/module.modulemap" <<'EOF'
module LimLinkCoreFFI {
    header "limlink_core.h"
    export *
}
EOF

# Release static libs only. A test symbol here means the wrong crate was linked.
for archive in "$stage/ios/liblimlink_core.a" "$stage/sim/liblimlink_core.a" "$stage/mac/liblimlink_core.a"; do
  if nm -gU "$archive" | awk '{print $NF}' | grep -q '^llct_'; then
    echo "$archive exports llct_" >&2
    exit 1
  fi
  if ! nm -gU "$archive" | awk '{print $NF}' | grep -q '^llc_abi_version$'; then
    echo "$archive is missing llc_abi_version" >&2
    exit 1
  fi
done

xcodebuild -create-xcframework \
  -library "$stage/ios/liblimlink_core.a" -headers "$stage/headers" \
  -library "$stage/sim/liblimlink_core.a" -headers "$stage/headers" \
  -library "$stage/mac/liblimlink_core.a" -headers "$stage/headers" \
  -output "$stage/LimLinkCoreFFI.xcframework"

framework="$stage/LimLinkCoreFFI.xcframework"
for slice in ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64; do
  hdr="$framework/$slice/Headers"
  nested="$hdr/LimLinkCoreFFI"
  mkdir -p "$nested"
  # xcodebuild copies the -headers tree. If a slice still has the files at
  # Headers/ root, move them so they cannot collide with another XCFramework.
  if [[ -f "$hdr/limlink_core.h" ]]; then
    mv "$hdr/limlink_core.h" "$nested/limlink_core.h"
  fi
  if [[ -f "$hdr/module.modulemap" ]]; then
    mv "$hdr/module.modulemap" "$nested/module.modulemap"
  fi
  if [[ ! -f "$nested/limlink_core.h" ]]; then
    echo "missing header in slice $slice" >&2
    find "$framework" -maxdepth 4 -type d -print >&2
    exit 1
  fi
  if [[ ! -f "$nested/module.modulemap" ]]; then
    echo "missing module.modulemap in slice $slice" >&2
    exit 1
  fi
  if [[ -e "$hdr/module.modulemap" ]]; then
    echo "slice $slice still has Headers/module.modulemap" >&2
    exit 1
  fi
  if ! grep -q 'module LimLinkCoreFFI' "$nested/module.modulemap"; then
    echo "module name is not LimLinkCoreFFI in slice $slice" >&2
    exit 1
  fi
  if ! grep -q 'header "limlink_core.h"' "$nested/module.modulemap"; then
    echo "modulemap header path is not relative to Headers/LimLinkCoreFFI in slice $slice" >&2
    exit 1
  fi
done

mkdir -p "$zip_dir"
ditto -c -k --keepParent "$framework" "$zip_dir/LimLinkCoreFFI.xcframework.zip"
swift package compute-checksum "$zip_dir/LimLinkCoreFFI.xcframework.zip" \
  >"$zip_dir/LimLinkCoreFFI.xcframework.checksum.txt"
echo "wrote $zip_dir/LimLinkCoreFFI.xcframework.zip"
