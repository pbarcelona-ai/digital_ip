#!/usr/bin/env python3
# ***************
# Filename: gen_status.py
# Author: FPGA Cores 4 U
# Description: Builds docs/STATUS.md from the last verification run - the
#   simulation result log, the Yosys result log and the Yosys utilization
#   and logic-depth reports of every IP under build/yosys. Logic depth is
#   the longest topological path in coarse cells reported by Yosys LTP and
#   is only a rough indicator (no static timing). Usage - gen_status.py
#   rootdir simlog yosyslog.
# Date: 2026-09-29
import re, sys, os
root, simlog, ylog = sys.argv[1:4]
rows = [l.strip().split(",") for l in open(f"{root}/scripts/ips.csv")
    if l.strip() and not l.startswith("#") and l.strip().split(",")[1] != "scalers"]
sim = dict(l.split(": ", 1) for l in open(simlog).read().splitlines() if ": " in l)
ys = dict(l.split(": ", 1) for l in open(ylog).read().splitlines() if ": " in l)
out = ["# Verification status", "", "Last full run: every general-purpose IP testbench with Icarus Verilog 12, every general-purpose IP synthesized with Yosys 0.33 `synth_xilinx` (7 series). The scaler family has its own regression and synthesis flow under `tools/`. LUT/FF/BRAM/DSP counts are Yosys estimates for default parameters; depth is the longest coarse-cell path from Yosys LTP (rough indicator, not timing; 0 means no path was reported). Watch ecc_memory_ctrl (depth 54: scrub decode-then-encode path is combinational, expect to add a pipeline stage for 100 MHz) and the wide DSP blocks.", "",
       "| IP | Category | Simulation | Yosys | LUT | FF | BRAM18/36 | DSP | Depth |", "|---|---|---|---|---|---|---|---|---|"]
tp = ok = 0
for n, c, t in rows:
    s = "PASS" if "PASSED" in sim.get(n, "") else "FAIL"; y = "OK" if ys.get(n, "").startswith("OK") else "FAIL"
    tp += s == "PASS"; ok += y == "OK"
    lut = ff = b18 = b36 = dsp = 0; depth = 0
    p = f"{root}/build/yosys/{n}/utilization_flat.rpt"
    if os.path.exists(p):
        for l in open(p):
            m = re.match(r"\s+(\w+)\s+(\d+)\s*$", l)
            if not m: continue
            k, v = m.group(1), int(m.group(2))
            if re.match(r"LUT[1-6]$", k) or k in ("RAM32M", "RAM64M", "RAM32X1D", "RAM64X1D", "RAM32X1S", "RAM64X1S", "RAM128X1D", "RAM256X1S"): lut += v
            elif k in ("FDRE", "FDSE", "FDCE", "FDPE"): ff += v
            elif k == "RAMB18E1": b18 += v
            elif k == "RAMB36E1": b36 += v
            elif k.startswith("DSP48"): dsp += v
    q = f"{root}/build/yosys/{n}/logic_depth_summary.rpt"
    if os.path.exists(q):
        for l in open(q):
            m = re.search(r"length=(\d+)", l)
            if m: depth = max(depth, int(m.group(1)))
    out.append(f"| {n} | {c} | {s} | {y} | {lut} | {ff} | {b18}/{b36} | {dsp} | {depth} |")
out += ["", f"Simulation passed: {tp}/{len(rows)}. Yosys clean: {ok}/{len(rows)}.", ""]
open(f"{root}/docs/STATUS.md", "w").write("\n".join(out))
print(f"gen_status: sim {tp}/{len(rows)}, yosys {ok}/{len(rows)}")
