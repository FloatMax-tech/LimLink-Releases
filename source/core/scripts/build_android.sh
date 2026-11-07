#!/usr/bin/env bash
# Link Android cdylibs with NDK r28+ (16 KB pages by default) and API 29.
# Always passes -Wl,-z,max-page-size=16384 and checks every LOAD segment.
#
# Usage, from anywhere:
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build_android.sh
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build_android.sh --zip /tmp/out
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

ndk="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to NDK r28 or newer}"
prebuilt=""
for tag in linux-x86_64 darwin-arm64 darwin-x86_64; do
  if [[ -x "$ndk/toolchains/llvm/prebuilt/$tag/bin/clang" ]]; then
    prebuilt="$ndk/toolchains/llvm/prebuilt/$tag"
    break
  fi
done
if [[ -z "$prebuilt" ]]; then
  echo "no LLVM prebuilt under $ndk" >&2
  exit 1
fi

bin="$prebuilt/bin"
page_flag="-C link-arg=-Wl,-z,max-page-size=16384"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$bin/aarch64-linux-android29-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$bin/x86_64-linux-android29-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$page_flag"
export CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS="$page_flag"

cargo build --release -p limlink-core --target aarch64-linux-android
cargo build --release -p limlink-core --target x86_64-linux-android
# test-rng is refused in the release profile, so the test .so stays a dev build.
cargo build -p limlink-core-testvectors --features bundled-llc --target aarch64-linux-android
cargo build -p limlink-core-testvectors --features bundled-llc --target x86_64-linux-android

check() {
  local lib="$1"
  shift
  python3 scripts/check_shipped_exports.py elf \
    --lib "$lib" \
    --min-align 0x4000 \
    --nm "$bin/llvm-nm" \
    "$@"
}

release_so() {
  local triple="$1"
  printf '%s\n' "$root/target/$triple/release/liblimlink_core.so"
}

test_so() {
  local triple="$1"
  printf '%s\n' "$root/target/$triple/debug/liblimlink_core_testvectors.so"
}

check "$(release_so aarch64-linux-android)" --require llc=include/limlink_core.h --forbid-prefix llct_
check "$(release_so x86_64-linux-android)" --require llc=include/limlink_core.h --forbid-prefix llct_
check "$(test_so aarch64-linux-android)" \
  --require llc=include/limlink_core.h \
  --require llct=include/limlink_core_testvectors.h
check "$(test_so x86_64-linux-android)" \
  --require llc=include/limlink_core.h \
  --require llct=include/limlink_core_testvectors.h

if [[ -z "$zip_dir" ]]; then
  exit 0
fi

mkdir -p "$zip_dir"
python3 - "$root" "$zip_dir" <<'PY'
import pathlib, sys, zipfile
root, out = map(pathlib.Path, sys.argv[1:])
header = root / "include" / "limlink_core.h"
test_header = root / "include" / "limlink_core_testvectors.h"

def pack(name, lib, abi, headers):
    dest = out / name
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.write(lib, f"jni/{abi}/{lib.name}")
        for header_path in headers:
            zf.write(header_path, f"include/{header_path.name}")
    print(dest)

pairs = [
    ("arm64-v8a", "aarch64-linux-android"),
    ("x86_64", "x86_64-linux-android"),
]
for abi, triple in pairs:
    release = root / "target" / triple / "release" / "liblimlink_core.so"
    test = root / "target" / triple / "debug" / "liblimlink_core_testvectors.so"
    pack(f"limlink-android-{abi}.zip", release, abi, [header])
    pack(f"limlink-android-{abi}-test.zip", test, abi, [header, test_header])
PY
