#!/usr/bin/env python3
# ***************
# Filename: cov_report.py
# Author: FPGA Cores 4 U
# Description: Merge the Verilator coverage data of a coverage run and
#   summarize it per RTL source file (line, branch, expression, toggle).
#   Instances of the same module are combined: a point counts as hit when
#   any instance hit it. Testbench files are left out of the summary.
# Date: 2026-10-09
#
# Usage: tools/cov/cov_report.py <out_dir> [--root <dir>] [--include-tb]
#   reads <out_dir>/data/*.dat and writes in <out_dir>:
#     merged.dat     all runs merged (verilator_coverage input)
#     coverage.info  LCOV tracefile (genhtml coverage.info -o html)
#     annotated/     sources annotated with hit counts (%000000 = never hit)
#     summary.txt    per-file table, also printed
#     summary.csv
import argparse, collections, csv, glob, os, re, subprocess, sys

TYPES = ("line", "branch", "expr", "toggle")
TB_DIRS = {"tb", "tb_verilog", "tests", "scale_verify", "python"}


def is_testbench(path):
    parts = path.split(os.sep)
    base = os.path.basename(path)
    return (TB_DIRS.intersection(parts[:-1]) or "tb_lib" in path
            or base.startswith("tb_") or re.search(r"_tb\.s?v$", base))


def points(dat):
    """(file, type, key) -> hit for every point in a Verilator coverage file."""
    with open(dat, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"C '(.*)' (\d+)$", line.rstrip("\n"))
            if not m:
                continue
            kv = dict(item.split("\x02", 1) for item in m.group(1).split("\x01") if "\x02" in item)
            kind = kv.get("page", "").split("/")[0].removeprefix("v_")
            kind = kv.get("t") if kind not in TYPES and kv.get("t") in TYPES else kind
            key = (kv.get("l"), kv.get("n"), kv.get("o"), kv.get("page"), kv.get("S"))
            yield os.path.realpath(kv.get("f", "?")), kind, key, int(m.group(2))


def pct(hit, total):
    return f"{100.0 * hit / total:5.1f}%" if total else "    - "


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out_dir")
    ap.add_argument("--root", default=os.getcwd(), help="paths in the summary are relative to this")
    ap.add_argument("--include-tb", action="store_true", help="also list testbench files")
    a = ap.parse_args()
    dats = sorted(glob.glob(os.path.join(a.out_dir, "data", "*.dat")))
    if not dats:
        sys.exit(f"cov_report: no coverage data in {a.out_dir}/data (did the simulation run?)")
    merged = os.path.join(a.out_dir, "merged.dat")
    vc = ["verilator_coverage"]
    subprocess.run(vc + ["--write", merged] + dats, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(vc + ["--write-info", os.path.join(a.out_dir, "coverage.info"), merged],
                   check=True, stdout=subprocess.DEVNULL)
    ann = subprocess.run(vc + ["--annotate", os.path.join(a.out_dir, "annotated"), "--annotate-min", "1", merged],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if ann.returncode:
        print(f"cov_report: warning: annotation incomplete: {ann.stderr.strip().splitlines()[0]}", file=sys.stderr)

    hits = collections.defaultdict(dict)                # file -> (kind, key) -> hit
    for path, kind, key, count in points(merged):
        if kind in TYPES:
            pts = hits[path]
            pts[(kind, key)] = pts.get((kind, key), False) or count > 0
    rows, totals = [], {t: [0, 0] for t in TYPES}
    for path in sorted(hits):
        if is_testbench(path) and not a.include_tb:
            continue
        per = {t: [0, 0] for t in TYPES}
        for (kind, _), hit in hits[path].items():
            per[kind][0] += hit; per[kind][1] += 1
        for t in TYPES:
            totals[t][0] += per[t][0]; totals[t][1] += per[t][1]
        rows.append((os.path.relpath(path, a.root), per))
    if not rows:
        sys.exit("cov_report: coverage data holds no RTL (non-testbench) files")

    width = max(len(r[0]) for r in rows + [("TOTAL", None)])
    head = f"{'file':<{width}}  " + "  ".join(f"{t:>18}" for t in TYPES)
    lines = [head, "-" * len(head)]
    fmt = lambda per: "  ".join(f"{pct(*per[t])} {per[t][0]:>5}/{per[t][1]:<5}".rjust(18) for t in TYPES)
    for path, per in rows:
        lines.append(f"{path:<{width}}  {fmt(per)}")
    lines += ["-" * len(head), f"{'TOTAL':<{width}}  {fmt(totals)}"]
    text = "\n".join(lines) + "\n"
    with open(os.path.join(a.out_dir, "summary.txt"), "w") as f:
        f.write(text)
    with open(os.path.join(a.out_dir, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file"] + [f"{t}_{x}" for t in TYPES for x in ("hit", "total")])
        for path, per in rows + [("TOTAL", totals)]:
            w.writerow([path] + [v for t in TYPES for v in per[t]])
    print(text, end="")
    print(f"coverage report: {a.out_dir}/summary.txt  (annotated sources: {a.out_dir}/annotated, "
          f"LCOV: {a.out_dir}/coverage.info)")


if __name__ == "__main__":
    main()
