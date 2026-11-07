#!/usr/bin/env bash
# Cross-link MSVC cdylibs on Linux with cargo-xwin (clang-cl, lld-link, llvm-lib).
# Release zips contain limlink_core.dll, the import library, and a PDB.
# The test DLL is a dev-profile build: test-rng cannot be linked in release.
#
# Usage:
#   ./scripts/build_windows.sh
#   ./scripts/build_windows.sh --abi x86_64
#   ./scripts/build_windows.sh --zip /tmp/out
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

zip_dir=""
abi="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      zip_dir="${2:?--zip needs a directory}"
      shift 2
      ;;
    --abi)
      abi="${2:?--abi needs x86_64, aarch64, or all}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$abi" in
  x86_64) triples=(x86_64-pc-windows-msvc) ;;
  aarch64) triples=(aarch64-pc-windows-msvc) ;;
  all) triples=(x86_64-pc-windows-msvc aarch64-pc-windows-msvc) ;;
  *)
    echo "unknown abi: $abi" >&2
    exit 2
    ;;
esac

if ! command -v cargo-xwin >/dev/null 2>&1; then
  echo "cargo-xwin is not on PATH" >&2
  exit 1
fi

# Full debuginfo so rustc writes a PDB next to the release DLL.
export CARGO_PROFILE_RELEASE_DEBUG=true

for triple in "${triples[@]}"; do
  cargo xwin build --release -p limlink-core --target "$triple"
  cargo xwin build -p limlink-core-testvectors --features bundled-llc --target "$triple"
done

readobj="${LLVM_READOBJ:-llvm-readobj}"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "missing $path" >&2
    find "$(dirname "$path")" -maxdepth 2 -type f -print >&2 || true
    exit 1
  fi
}

# rustc sometimes leaves the PDB beside the hashed dep instead of the final DLL.
ensure_pdb() {
  local dir="$1"
  local stem="$2"
  if [[ -f "$dir/$stem.pdb" ]]; then
    return 0
  fi
  local found=""
  found="$(find "$dir" -type f \( -name "$stem.pdb" -o -name "${stem}-*.pdb" \) -print -quit)"
  if [[ -z "$found" ]]; then
    echo "missing PDB for $stem under $dir" >&2
    find "$dir" -name '*.pdb' -print >&2 || true
    exit 1
  fi
  cp "$found" "$dir/$stem.pdb"
}

for triple in "${triples[@]}"; do
  release_dir="$root/target/$triple/release"
  test_dir="$root/target/$triple/debug"
  require_file "$release_dir/limlink_core.dll"
  require_file "$release_dir/limlink_core.dll.lib"
  ensure_pdb "$release_dir" limlink_core
  require_file "$test_dir/limlink_core_testvectors.dll"
  require_file "$test_dir/limlink_core_testvectors.dll.lib"
  ensure_pdb "$test_dir" limlink_core_testvectors
  python3 scripts/check_shipped_exports.py coff \
    --lib "$release_dir/limlink_core.dll" \
    --readobj "$readobj" \
    --require llc=include/limlink_core.h \
    --forbid-prefix llct_
  python3 scripts/check_shipped_exports.py coff \
    --lib "$test_dir/limlink_core_testvectors.dll" \
    --readobj "$readobj" \
    --require llc=include/limlink_core.h \
    --require llct=include/limlink_core_testvectors.h
done

if [[ -z "$zip_dir" ]]; then
  exit 0
fi

mkdir -p "$zip_dir"
python3 - "$root" "$zip_dir" "${triples[@]}" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
triples = sys.argv[3:]
header = root / "include" / "limlink_core.h"
test_header = root / "include" / "limlink_core_testvectors.h"
labels = {
    "x86_64-pc-windows-msvc": "x86_64",
    "aarch64-pc-windows-msvc": "aarch64",
}

def pack(name, directory, stem, headers):
    dest = out / name
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for suffix in (".dll", ".dll.lib", ".pdb"):
            path = directory / f"{stem}{suffix}"
            zf.write(path, path.name)
        for header_path in headers:
            zf.write(header_path, f"include/{header_path.name}")
    print(dest)

for triple in triples:
    label = labels[triple]
    pack(
        f"limlink-windows-{label}.zip",
        root / "target" / triple / "release",
        "limlink_core",
        [header],
    )
    pack(
        f"limlink-windows-{label}-test.zip",
        root / "target" / triple / "debug",
        "limlink_core_testvectors",
        [header, test_header],
    )
PY
