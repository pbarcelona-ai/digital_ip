#!/usr/bin/env python3
# ***************
# Filename: stamp_version.py
# Author: FPGA Cores 4 U
# Description: Keeps the ID block of every IP with a register map current.
#   Each such IP declares, in its own source file,
#     localparam logic [31:0] IP_ID      = "ABCD";
#     localparam logic [31:0] IP_VERSION = "1.00";        // ASCII major.minor
#     localparam logic [31:0] IP_DATE    = 32'h10112026;  // BCD mm/dd/yyyy
#   readable at 0x00 / 0x04 / 0x08 of its register map. When a SystemVerilog
#   file of an IP changes (anything other than these stamp lines), the IP's
#   version goes up by 0.01 (1.09 -> 1.10, 1.99 -> 2.00) and its date becomes
#   today, once per run. The IP of a changed file is its directory up to the
#   one holding src/; its stamp is the src/*.sv or src/include/*.sv file
#   that has IP_VERSION (the generated register map, src/include/<ip>_regs.sv).
#   Run by the git pre-commit hook (scripts/hooks/pre-commit) on the staged
#   files, the stamped files are staged again. A stamped <ip>_regs.sv
#   generated from <ip>_regs.json is regenerated (regmap_gen.py keeps the new
#   stamp), so its IP-XACT .xml and docs carry the same version and date.
# Date: 2026-10-11
# ***************
# Usage: ip/scripts/stamp_version.py [--staged | --all | FILE ...] [--check] [--dry-run]
#                                    [--install-hook]
#   --staged       the files staged in git (default)
#   --all          every .sv file changed in the work tree against HEAD
#   FILE ...       these files
#   --check        change nothing; exit 1 if a changed IP still has an old
#                  stamp (version not above HEAD's, or date not today)
#   --dry-run      print what would change
#   --install-hook install scripts/hooks/pre-commit as the repository's hook
from __future__ import annotations

import argparse
import datetime
import re
import shutil
import subprocess
import sys
from pathlib import Path

STAMP_RE = re.compile(r'^(\s*localparam\s+logic\s*\[31:0\]\s*IP_(VERSION|DATE)\s*=\s*)([^;]+)(;.*)$', re.M)
VER_RE = re.compile(r'^"(\d)\.(\d\d)"$')


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


def repo_root() -> Path:
    return Path(git("rev-parse", "--show-toplevel").strip())


def strip_stamps(text: str) -> str:
    return STAMP_RE.sub(lambda m: m.group(1) + "<stamp>" + m.group(4), text)


def head_text(root: Path, path: Path) -> str | None:
    try:
        return git("show", f"HEAD:{path.relative_to(root).as_posix()}", cwd=root)
    except subprocess.CalledProcessError:
        return None                                      # new file


def stamp_file(f: Path) -> Path | None:
    """The source file holding the IP_VERSION stamp of the IP that f belongs to."""
    d = f.parent
    while d != d.parent:
        if (d / "src").is_dir():
            for c in sorted((d / "src" / "include").glob("*.sv")) + sorted((d / "src").glob("*.sv")):
                if "IP_VERSION" in c.read_text(encoding="utf-8", errors="replace"):
                    return c
            return None
        d = d.parent
    return None


def changed(root: Path, f: Path, staged: bool) -> bool:
    """f differs from HEAD in more than its stamp lines."""
    old = head_text(root, f)
    if staged:
        try:
            new = git("show", f":{f.relative_to(root).as_posix()}", cwd=root)
        except subprocess.CalledProcessError:
            return False
    else:
        new = f.read_text(encoding="utf-8")
    return old is None or strip_stamps(old) != strip_stamps(new)


def next_version(v: str) -> str:
    m = VER_RE.match(v.strip())
    if not m:
        raise ValueError(f"version {v.strip()} is not \"d.dd\"")
    n = int(m.group(1)) * 100 + int(m.group(2)) + 1
    if n > 999:
        raise ValueError("version above 9.99")
    return f'"{n // 100}.{n % 100:02d}"'


def today_bcd() -> str:
    t = datetime.date.today()
    return f"32'h{t.month:02d}{t.day:02d}{t.year:04d}"


def stamps(text: str) -> dict[str, str]:
    return {m.group(2): m.group(3).strip() for m in STAMP_RE.finditer(text)}


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--staged", action="store_true")
    g.add_argument("--all", action="store_true")
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--install-hook", action="store_true")
    a = ap.parse_args()
    root = repo_root()
    if a.install_hook:
        hooks = Path(git("rev-parse", "--git-path", "hooks").strip())
        hooks = hooks if hooks.is_absolute() else root / hooks
        hooks.mkdir(parents=True, exist_ok=True)
        src = Path(__file__).resolve().parent / "hooks" / "pre-commit"
        shutil.copy(src, hooks / "pre-commit")
        (hooks / "pre-commit").chmod(0o755)
        print(f"installed {hooks / 'pre-commit'}")
        return 0
    staged = not (a.all or a.files)
    if a.files:
        files = [f.resolve() for f in a.files]
    elif a.all:
        files = [root / p for p in git("diff", "--name-only", "HEAD", cwd=root).split()]
        files += [root / p for p in git("ls-files", "--others", "--exclude-standard", cwd=root).split()]
    else:
        files = [root / p for p in git("diff", "--cached", "--name-only", "--diff-filter=ACMR", cwd=root).split()]
    files = [f for f in files if f.suffix in (".sv", ".svh") and f.is_file()]
    todo: dict[Path, list[Path]] = {}
    for f in files:
        s = stamp_file(f)
        if s is not None and changed(root, f, staged and not a.files):
            todo.setdefault(s, []).append(f)
    stale = 0
    for s, why in sorted(todo.items()):
        text = s.read_text(encoding="utf-8")
        cur = stamps(text)
        old = stamps(head_text(root, s) or "")
        if "VERSION" not in cur or "DATE" not in cur:
            print(f"{s}: no IP_VERSION / IP_DATE stamp", file=sys.stderr)
            stale += 1
            continue
        base = old.get("VERSION", cur["VERSION"])
        try:
            want_v = next_version(base) if "VERSION" in old else cur["VERSION"]
        except ValueError as e:
            print(f"{s}: {e}", file=sys.stderr)
            stale += 1
            continue
        want_d = today_bcd()
        ok_v = VER_RE.match(cur["VERSION"]) and (cur["VERSION"] == want_v or
                                                 (int(cur["VERSION"][1]) * 100 + int(cur["VERSION"][3:5]) >=
                                                  int(want_v[1]) * 100 + int(want_v[3:5])))
        if ok_v and cur["DATE"] == want_d:
            continue
        rel = s.relative_to(root)
        if a.check:
            print(f"{rel}: stamp {cur['VERSION']} {cur['DATE']}, expected {want_v} {want_d} "
                  f"(changed: {', '.join(p.name for p in why)})")
            stale += 1
            continue
        new_v = cur["VERSION"] if ok_v else want_v
        text = STAMP_RE.sub(lambda m: m.group(1) + (new_v if m.group(2) == "VERSION" else want_d) + m.group(4), text)
        print(f"{rel}: {cur['VERSION']} -> {new_v}, date {want_d}")
        if not a.dry_run:
            s.write_text(text, encoding="utf-8")
            js = s.with_suffix(".json")                  # generated map: refresh its XML / docs with the new stamp
            if js.is_file():
                subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "regmap_gen.py"), str(js)],
                               check=True, capture_output=True)
            if staged:
                git("add", str(s), cwd=root)
                if js.is_file() and s.with_suffix(".xml").is_file():
                    git("add", str(s.with_suffix(".xml")), cwd=root)
    return 1 if (a.check and stale) else 0


if __name__ == "__main__":
    sys.exit(main())
