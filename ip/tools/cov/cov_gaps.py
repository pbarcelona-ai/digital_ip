#!/usr/bin/env python3
# ***************
# Filename: cov_gaps.py
# Author: FPGA Cores 4 U
# Description: List the coverage holes of a coverage run (scripts/run_cov.sh
#   output) per RTL file: every never-hit line, branch and expression point
#   with its source line, and per signal the toggle bits that never moved.
#   Instances of the same module are combined (hit by any instance = hit).
# Date: 2026-10-09
#
# Usage: tools/cov/cov_gaps.py <out_dir> [--no-toggle] [--file <substring>]
import argparse, collections, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cov_report import is_testbench, TYPES  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--no-toggle", action="store_true")
    ap.add_argument("--file", default="")
    a = ap.parse_args()
    pts = collections.defaultdict(dict)   # file -> key -> [kind, line, desc, hit]
    for line in open(os.path.join(a.out_dir, "merged.dat"), encoding="utf-8", errors="replace"):
        m = re.match(r"C '(.*)' (\d+)$", line.rstrip("\n"))
        if not m:
            continue
        kv = dict(x.split("\x02", 1) for x in m.group(1).split("\x01") if "\x02" in x)
        kind = kv.get("page", "").split("/")[0].removeprefix("v_")
        if kind not in TYPES:
            continue
        f = os.path.realpath(kv.get("f", "?"))
        if is_testbench(f) or a.file not in f:
            continue
        key = (kind, kv.get("l"), kv.get("n"), kv.get("o"), kv.get("S"))
        e = pts[f].setdefault(key, [kind, int(kv.get("l", 0)), kv.get("o", ""), False])
        e[3] = e[3] or int(m.group(2)) > 0
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    for f in sorted(pts):
        miss = [e for e in pts[f].values() if not e[3]]
        if not miss:
            continue
        try:
            src = open(f, encoding="utf-8", errors="replace").read().split("\n")
        except OSError:
            src = []
        print(f"== {os.path.relpath(f, root)}")
        by_line = collections.defaultdict(list)
        tog = collections.defaultdict(lambda: [0, set()])
        for kind, ln, desc, _ in miss:
            if kind == "toggle":
                sig, _, edge = desc.rpartition(":")
                base = re.sub(r"\[\d+\]$", "", sig)
                tog[base][0] += 1
                tog[base][1].add(edge)
            else:
                by_line[ln].append(f"{kind}:{desc}")
        for ln in sorted(by_line):
            text = src[ln - 1].strip() if 0 < ln <= len(src) else ""
            print(f"  {ln:5d}  {', '.join(sorted(set(by_line[ln])))[:70]:<70}  | {text[:90]}")
        if tog and not a.no_toggle:
            items = sorted(tog.items())
            print("  toggle (signal: untoggled bit-edges):", ", ".join(f"{s}:{n}" for s, (n, _) in items))


if __name__ == "__main__":
    main()
