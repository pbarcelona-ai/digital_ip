#!/usr/bin/env python3
# ***************
# Filename: summarize.py
# Author: Paul Barcelona
# Description: Parses a Yosys utilization_hier.rpt and prints a compact
# resource line (LUT, FF, DSP48, BRAM, SRL, CARRY4, total cells). Uses the
# rolled-up "design hierarchy" block when present (multi-module designs),
# otherwise the module's own block. Used by run_yosys.sh and
# run_all_yosys.sh.
# Date: September 26, 2026
# ***************
"""Usage: summarize.py <utilization_hier.rpt>   -> one-line resource summary"""
import re, sys

def parse(path):
    text = open(path).read()
    blocks = re.split(r"\n=== (.+?) ===\n", text)
    # blocks: [pre, name1, body1, name2, body2, ...]
    named = {blocks[i]: blocks[i + 1] for i in range(1, len(blocks) - 1, 2)}
    body = named.get("design hierarchy")
    if body is None:                       # single-module design: last block
        body = blocks[-1]
    cells = {}
    for pattern, count_group, cell_group in (
        (r"^\s{4,}([A-Z][A-Z0-9_]+)\s+(\d+)\s*$", 2, 1),
        (r"^\s{4,}(\d+)\s+([A-Z][A-Z0-9_]+)\s*$", 1, 2),
    ):
        for match in re.finditer(pattern, body, re.M):
            cells[match.group(cell_group)] = int(match.group(count_group))
    m = re.search(r"Number of cells:\s+(\d+)", body)
    if m is None:
        m = re.search(r"^\s*(\d+)\s+cells\s*$", body, re.M)
    if not cells:
        raise ValueError(f"No cell counts found in Yosys report: {path}")
    total = int(m.group(1)) if m else sum(cells.values())
    return cells, total

def summary(path):
    c, total = parse(path)
    lut = sum(v for k, v in c.items() if re.fullmatch(r"LUT[1-6]", k))
    ff = sum(v for k, v in c.items() if k.startswith("FD"))
    dsp = c.get("DSP48E1", 0)
    bram36, bram18 = c.get("RAMB36E1", 0), c.get("RAMB18E1", 0)
    srl = c.get("SRL16E", 0) + c.get("SRLC32E", 0)
    return dict(lut=lut, ff=ff, dsp=dsp, bram36=bram36, bram18=bram18,
                srl=srl, carry4=c.get("CARRY4", 0), cells=total)

def line(s):
    return (f"LUT={s['lut']}  FF={s['ff']}  DSP48E1={s['dsp']}  "
            f"RAMB36={s['bram36']}  RAMB18={s['bram18']}  SRL={s['srl']}  "
            f"CARRY4={s['carry4']}  cells={s['cells']}")

if __name__ == "__main__":
    print(line(summary(sys.argv[1])))
