#!/usr/bin/env python3
"""Generate the file manifest used to build IP ZIP bundles in the browser."""
from __future__ import annotations

import csv
import json
from pathlib import Path
import stat


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "download-manifest.json"
SKIP_DIRS = {".git", "__pycache__", "sim_out", "yosys"}
SUPPORT_FILES = (
    ".tools",
    "Makefile",
    "README.md",
    "SCALER_README.md",
    "requirements-python-test.txt",
    "docs/site.css",
)
SUPPORT_DIRS = ("scripts", "tools", "shared", "include", "assertions", "scalers/scaler_tb_lib")


def catalog() -> list[tuple[str, str, str]]:
    with (ROOT / "scripts/ips.csv").open(encoding="utf-8", newline="") as source:
        return [(name, category, top) for name, category, top in csv.reader(source)
                if name and not name.startswith("#")]


def add_file(path: Path, files: set[Path]) -> None:
    resolved = path.resolve()
    resolved.relative_to(ROOT)
    if resolved.is_file():
        files.add(resolved)


def add_tree(directory: Path, files: set[Path]) -> None:
    if not directory.is_dir():
        return
    for path in directory.rglob("*"):
        relative = path.relative_to(directory)
        if any(part in SKIP_DIRS for part in relative.parts):
            continue
        if path.is_file():
            add_file(path, files)


def add_manifest(manifest: Path, base: Path, files: set[Path]) -> None:
    if not manifest.is_file():
        return
    for line_number, raw in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        entry = raw.split("//", 1)[0].split("#", 1)[0].strip()
        if not entry or entry.startswith(("+", "-")):
            continue
        source = (base / entry).resolve()
        try:
            source.relative_to(ROOT)
        except ValueError as error:
            raise ValueError(f"{manifest}:{line_number}: path escapes the repository: {entry}") from error
        if not source.is_file():
            raise FileNotFoundError(f"{manifest}:{line_number}: manifest source not found: {entry}")
        files.add(source)


def common_files() -> set[Path]:
    files: set[Path] = set()
    for relative in SUPPORT_FILES:
        add_file(ROOT / relative, files)
    for relative in SUPPORT_DIRS:
        add_tree(ROOT / relative, files)
    return files


def module_files(name: str, category: str) -> set[Path]:
    module = ROOT / category / name
    if not module.is_dir():
        raise FileNotFoundError(f"catalog module directory not found: {module}")

    files: set[Path] = set()
    add_tree(module, files)

    if category == "scalers":
        add_manifest(module / "src/build.f", module / "src", files)
        add_manifest(module / "tb/scripts/build.f", module / "tb/scripts", files)
    else:
        add_manifest(module / "scripts/build.f", module, files)
        add_manifest(module / "tb/scripts/build.f", module, files)
    return files


def file_record(path: Path) -> dict[str, str | bool]:
    return {
        "path": path.relative_to(ROOT).as_posix(),
        "executable": bool(path.stat().st_mode & stat.S_IXUSR),
    }


def main() -> None:
    rows = catalog()
    shared = common_files()
    modules = {}
    for name, category, top in rows:
        files = module_files(name, category) - shared
        modules[name] = {
            "category": category,
            "top": top,
            "files": [file_record(path) for path in sorted(files)],
        }

    manifest = {
        "base_url": "../",
        "common_files": [file_record(path) for path in sorted(shared)],
        "modules": modules,
    }
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    legacy_downloads = ROOT / "docs" / "downloads"
    if legacy_downloads.is_dir():
        for archive in legacy_downloads.glob("*.zip"):
            archive.unlink()
        try:
            legacy_downloads.rmdir()
        except OSError:
            pass
    print(f"generated browser download manifest for {len(modules)} IPs ({len(shared)} shared files)")


if __name__ == "__main__":
    main()