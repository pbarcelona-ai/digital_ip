#!/usr/bin/env bash
# ***************
# Filename: run_yosys.sh
# Author: Paul Barcelona
# Description: Runs Yosys synthesis (Xilinx 7-series, BRAM + DSP mapping)
# for this module. Reads the RTL list from build.f, then executes the
# shared common script ../../synth/yosys_common.ys (path adjusted per
# directory). Results (log, hierarchical utilization report, netlist)
# go to ./yosys/.
# Date: September 26, 2026
# ***************
# Usage: ./run_yosys.sh
set -euo pipefail
cd "$(dirname "$0")"

COMMON="../synth/yosys_common.ys"
OUT=yosys
rm -rf "$OUT"; mkdir -p "$OUT"

# Build the read_verilog file list from build.f (skip blanks/comments).
FILES=$(grep -v '^[[:space:]]*#' build.f | grep -v '^[[:space:]]*$' | tr '\n' ' ')

echo "[run_yosys] $(basename "$PWD"): reading: $FILES"
yosys -q -l "$OUT/yosys.log" -p "read_verilog -sv $FILES; script $COMMON"

echo "[run_yosys] done. Results in $PWD/$OUT/:"
ls -1 "$OUT"
echo "---- resource summary ----"
python3 "../synth/summarize.py" "$OUT/utilization_hier.rpt"
