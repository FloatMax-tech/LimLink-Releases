#!/usr/bin/env python3
"""Check committed C headers against the symbols cargo actually exports.

The headers in core/include/ are the spec text (15.10.8 / 15.10.9), written
by hand so the comments stay stable. This is the CI stand-in for a cbindgen
diff: every declared function must be exported, and the release library must
not export the test-only llct_* names or the +testrng version suffix.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
INCLUDE = ROOT / "include"


def declared(header: pathlib.Path, prefix: str) -> set[str]:
    text = header.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//.*?$", " ", text, flags=re.M)
    return set(re.findall(rf"\b({prefix}_[A-Za-z0-9_]+)\s*\(", text))


def nm_defined(path: pathlib.Path) -> set[str]:
    out = subprocess.check_output(
        ["nm", "-g", "--defined-only", str(path)],
        text=True,
        stderr=subprocess.STDOUT,
    )
    names: set[str] = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[-2] in set("TtDdRrBbWw"):
            names.add(parts[-1])
    return names


def require_libs(directory: pathlib.Path, stem: str) -> list[pathlib.Path]:
    libs = sorted(
        path
        for path in directory.glob(f"{stem}.*")
        if path.suffix in {".a", ".so", ".dylib", ".dll", ".lib"}
    )
    if not libs:
        raise SystemExit(f"no {stem} library under {directory}")
    return libs


def strings_has(path: pathlib.Path, needle: str) -> bool:
    data = path.read_bytes()
    return needle.encode() in data


def check_release() -> None:
    header = declared(INCLUDE / "limlink_core.h", "llc")
    if not header:
        raise SystemExit("no llc_* functions in limlink_core.h")
    for lib in require_libs(ROOT / "target" / "release", "liblimlink_core"):
        names = nm_defined(lib)
        missing = sorted(header - names)
        leaked = sorted(name for name in names if name.startswith("llct_"))
        if missing or leaked:
            raise SystemExit(f"{lib.name}: missing={missing} leaked={leaked}")
        if strings_has(lib, "+testrng"):
            raise SystemExit(f"{lib.name} contains +testrng")
        if any("limlink_core_testvectors" in name for name in names):
            raise SystemExit(f"{lib.name} exports limlink_core_testvectors")
        print(f"release ok: {lib.name} ({len(header)} llc_* symbols)")


def check_testvectors() -> None:
    header = declared(INCLUDE / "limlink_core_testvectors.h", "llct")
    release = declared(INCLUDE / "limlink_core.h", "llc")
    if header != {name.replace("llc_", "llct_", 1) for name in release}:
        raise SystemExit("llct_* declarations are not a 1:1 rename of llc_*")
    found_suffix = False
    for lib in require_libs(ROOT / "target" / "debug", "liblimlink_core_testvectors"):
        names = nm_defined(lib)
        missing = sorted(header - names)
        leaked = sorted(
            name for name in names if name.startswith("llc_") and not name.startswith("llct_")
        )
        if missing or leaked:
            raise SystemExit(f"{lib.name}: missing={missing} leaked={leaked}")
        if strings_has(lib, "+testrng"):
            found_suffix = True
        print(f"testvectors ok: {lib.name} ({len(header)} llct_* symbols)")
    if not found_suffix:
        raise SystemExit("debug testvectors library does not contain +testrng")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--testvectors", action="store_true")
    args = parser.parse_args()
    if args.release == args.testvectors:
        parser.error("pass exactly one of --release or --testvectors")
    if args.release:
        check_release()
    else:
        check_testvectors()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.output or "")
        raise
