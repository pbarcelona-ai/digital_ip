#!/usr/bin/env python3
# ***************
# Filename: list_tests.py
# Author: FPGA Cores 4 U
# Description: Lists the name of each test available to run in an IP or
#   system directory: every `task automatic test_<name>` in the testbench
#   test files (tb/tests/*_tests.sv, tb_verilog/**/tests/*_tests.sv, ...),
#   with the one-line description from the file header's task list, grouped
#   by testbench. Used by scripts/run_sim.sh --list-tests (library IP and
#   systems), `make list-tests`, and the prompt generators
#   (make_ip_prompts.py), so every prompt names the tests.
#   A testbench without test_* tasks runs as one test: it is listed under its
#   own name with the first sentence of its header description.
# Date: 2026-10-10
#
# Usage: list_tests.py <dir> [--names | --markdown]
#   (default) text, one "  name  description" line per test, grouped by file
#   --names     test names only, one per line
#   --markdown  a Markdown table (Testbench, Test, Description)
# ***************
import re, sys
from pathlib import Path

TASK_RE = re.compile(r"^\s*task\s+(?:automatic\s+)?(test_\w+)\s*\(", re.M)


def header_descriptions(text: str) -> dict[str, str]:
    """`//     name  description` entries of the leading comment; a more deeply indented line
    continues the entry above it."""
    desc, cur, cur_ind = {}, None, 0
    for line in text.splitlines():
        if not line.startswith("//"):
            break
        body = line[2:]
        ind = len(body) - len(body.lstrip(" "))
        if not body.strip():
            cur = None
            continue
        if cur and ind > cur_ind + 1:
            desc[cur] += " " + body.strip()
            continue
        m = re.match(r"\s{2,}(\w+)\s+(\S.*)$", body)
        if m and ind >= 4:                             # task entries are indented past the prose
            cur, cur_ind = m.group(1), ind
            desc[cur] = m.group(2).strip()
        else:
            cur = None
    return desc


def tb_summary(tb: Path) -> str:
    """First sentence of a testbench's header Description: what the single test checks."""
    if not tb.is_file():
        return "the whole testbench"
    text, desc = [], False
    for line in tb.read_text(errors="replace").splitlines():
        if not line.startswith("//"):
            break
        if line.startswith("// Description:"):
            desc = True
            text.append(line[len("// Description:"):].strip())
        elif desc and line.startswith("// ") and not re.match(r"//\s*(Date|\*)", line):
            text.append(line[2:].strip())
        elif desc:
            break
    s = " ".join(text)
    m = re.match(r"(.+?\.)(\s|$)", s)
    return "one test: " + ((m.group(1) if m else s) or "the whole testbench")


def testbench_of(test_file: Path) -> str:
    """The testbench a test-task file belongs to: tests/<x>_tests.sv -> <x>_tb / tb_<x>."""
    base = test_file.name[:-len("_tests.sv")]
    tb_dir = test_file.parent.parent
    for cand in (f"{base}_tb.sv", f"tb_{base}.sv", f"{base}.sv"):
        if (tb_dir / cand).is_file():
            return cand[:-3]
    return base


def tests_for(d: Path) -> list[tuple[str, str, str]]:
    """[(testbench, test, description)] for every test file under d (build directories skipped)."""
    out = []
    files = sorted(p for p in d.rglob("*_tests.sv") if "build" not in p.relative_to(d).parts)
    covered = set()
    for f in files:
        text = f.read_text(errors="replace")
        desc = header_descriptions(text)
        tb = testbench_of(f)
        covered.add(tb)
        names = TASK_RE.findall(text)
        for n in names:
            out.append((tb, n, desc.get(n, "")))
        if not names:
            out.append((tb, tb, tb_summary(f.parent.parent / f"{tb}.sv")))
    # testbenches without a tests/ file run as one test
    for tb in sorted(list(d.rglob("*_tb.sv")) + list(d.rglob("tb_*.sv"))):
        if "build" in tb.relative_to(d).parts or tb.stem in covered:
            continue
        out.append((tb.stem, tb.stem, tb_summary(tb)))
    return out


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__ or "usage: list_tests.py <dir> [--names | --markdown]")
        sys.exit(2)
    d = Path(sys.argv[1]).resolve()
    mode = sys.argv[2] if len(sys.argv) > 2 else ""
    tests = tests_for(d)
    if not tests:
        print("(no testbench found)")
        return
    if mode == "--names":
        for _, n, _ in tests:
            print(n)
    elif mode == "--markdown":
        print("| Testbench | Test | Description |")
        print("|-----------|------|-------------|")
        for tb, n, s in tests:
            print(f"| `{tb}` | `{n}` | {s} |")
    else:
        last = None
        w = max(len(n) for _, n, _ in tests)
        for tb, n, s in tests:
            if tb != last:
                print(f"{tb}:")
                last = tb
            print(f"  {n:<{w}}  {s}")


if __name__ == "__main__":
    main()
