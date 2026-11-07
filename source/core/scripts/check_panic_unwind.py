#!/usr/bin/env python3
"""LLC_ERR_PANIC needs panic = \"unwind\". Fail if a profile selects abort."""

from __future__ import annotations

import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def walk(path: pathlib.Path, node: object, where: str) -> None:
    if isinstance(node, dict):
        if node.get("panic") == "abort":
            raise SystemExit(f'{path}: {where} sets panic = "abort"')
        for key, value in node.items():
            walk(path, value, f"{where}.{key}")


def check_file(path: pathlib.Path) -> None:
    if "target" in path.parts or not path.is_file():
        return
    walk(path, tomllib.loads(path.read_text(encoding="utf-8")), str(path.relative_to(ROOT)))


def main() -> None:
    workspace = ROOT / "core" / "Cargo.toml"
    data = tomllib.loads(workspace.read_text(encoding="utf-8"))
    profiles = data.get("profile", {})
    for name in ("dev", "release"):
        panic = profiles.get(name, {}).get("panic")
        if panic != "unwind":
            raise SystemExit(
                f'[profile.{name}] panic must be "unwind" so LLC_ERR_PANIC works, got {panic!r}'
            )
    for path in ROOT.rglob("Cargo.toml"):
        check_file(path)
    cargo_dir = ROOT / ".cargo"
    if cargo_dir.is_dir():
        for path in cargo_dir.rglob("*.toml"):
            check_file(path)
    print("panic = unwind")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — CI boundary
        print(f"check_panic_unwind: {exc}", file=sys.stderr)
        raise
