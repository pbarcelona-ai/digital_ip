#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

COMMON="../../synth/yosys_common.ys"
OUT=yosys
rm -rf "$OUT"; mkdir -p "$OUT"
FILES=$(grep -v '^[[:space:]]*#' scripts/build.f | grep -v '^[[:space:]]*$' | tr '\n' ' ')

echo "[run_yosys] $(basename "$PWD"): reading: $FILES"
yosys -q -l "$OUT/yosys.log" -p "read_verilog -sv $FILES; script $COMMON"
echo "[run_yosys] done. Results in $PWD/$OUT/:"
ls -1 "$OUT"
echo "---- resource summary ----"
python3 "../../synth/summarize.py" "$OUT/utilization_hier.rpt"
