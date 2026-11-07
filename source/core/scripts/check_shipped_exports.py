#!/usr/bin/env python3
"""Check symbols on a library we ship, and ELF LOAD alignment.

Release libraries must export every llc_* name from limlink_core.h and no
llct_* name. Packaged test libraries must export both headers. Other runtime
symbols (for example rust_eh_personality) are ignored.
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


def parse_require(text: str) -> tuple[str, pathlib.Path]:
    prefix, _, path = text.partition("=")
    if not prefix or not path:
        raise SystemExit(f"--require must be prefix=header, got {text!r}")
    header = pathlib.Path(path)
    if not header.is_absolute():
        header = ROOT / header
    return prefix, header


def nm_defined(path: pathlib.Path, nm: str, dynamic: bool) -> set[str]:
    cmd = [nm]
    if dynamic:
        cmd.append("-D")
    cmd.extend(["--defined-only", str(path)])
    out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
    names: set[str] = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[-2] in set("TtDdRrBbWw"):
            names.add(parts[-1])
        elif len(parts) == 2 and parts[0] in set("TtDdRrBbWw"):
            names.add(parts[1])
    return names


def coff_exports(path: pathlib.Path, readobj: str) -> set[str]:
    out = subprocess.check_output(
        [readobj, "--coff-exports", str(path)],
        text=True,
        stderr=subprocess.STDOUT,
    )
    names = set()
    for line in out.splitlines():
        stripped = line.strip()
        if stripped.startswith("Name:"):
            name = stripped.split(":", 1)[1].strip().strip('"')
            if name:
                names.add(name)
    if not names:
        raise SystemExit(f"{path}: llvm-readobj reported no COFF exports")
    return names


def load_aligns(path: pathlib.Path, readelf: str) -> list[int]:
    out = subprocess.check_output(
        [readelf, "-lW", str(path)],
        text=True,
        stderr=subprocess.STDOUT,
    )
    aligns: list[int] = []
    for line in out.splitlines():
        stripped = line.strip()
        if not stripped.startswith("LOAD"):
            continue
        fields = stripped.split()
        aligns.append(int(fields[-1], 16))
    if not aligns:
        raise SystemExit(f"{path}: no LOAD segments")
    return aligns


def check_names(path: pathlib.Path, names: set[str], args: argparse.Namespace) -> None:
    required: set[str] = set()
    for item in args.require:
        prefix, header = parse_require(item)
        found = declared(header, prefix)
        if not found:
            raise SystemExit(f"no {prefix}_* functions in {header}")
        required |= found
    missing = sorted(required - names)
    leaked = sorted(
        name
        for name in names
        if any(name.startswith(prefix) for prefix in args.forbid_prefix)
    )
    extra = sorted(
        name
        for name in names
        if (name.startswith("llc_") or name.startswith("llct_")) and name not in required
    )
    if missing or leaked or extra:
        raise SystemExit(
            f"{path.name}: missing={missing} leaked={leaked} extra={extra}"
        )
    print(f"exports ok: {path.name} ({len(required)} required symbols)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("elf", "coff"))
    parser.add_argument("--lib", type=pathlib.Path, required=True)
    parser.add_argument("--require", action="append", required=True)
    parser.add_argument("--forbid-prefix", action="append", default=[])
    parser.add_argument("--min-align", default="")
    parser.add_argument("--nm", default="nm")
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--readobj", default="llvm-readobj")
    args = parser.parse_args()
    lib = args.lib
    if not lib.is_file():
        raise SystemExit(f"missing library {lib}")
    if args.kind == "elf":
        names = nm_defined(lib, args.nm, dynamic=True)
        if args.min_align:
            minimum = int(args.min_align, 0)
            aligns = load_aligns(lib, args.readelf)
            bad = [hex(align) for align in aligns if align < minimum]
            if bad:
                raise SystemExit(f"{lib.name}: LOAD Align {bad} < {hex(minimum)}")
            print(f"align ok: {lib.name} LOAD {', '.join(hex(a) for a in aligns)}")
    else:
        names = coff_exports(lib, args.readobj)
    check_names(lib, names, args)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.output or "")
        raise
