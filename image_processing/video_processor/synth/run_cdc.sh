#!/usr/bin/env bash
# ***************
# Filename: run_cdc.sh
# Author: FPGA Cores 4 U
# Description: Structural clock-domain-crossing check of video_processor
#   (ip/scripts/cdc_check.py). Yosys reads scripts/build.f with the
#   yosys-slang front end (read_slang: the SystemVerilog as written,
#   interfaces included, one compilation unit; the NPU with an 8 x 8 array -
#   the crossings do not depend on it), flattens it and writes the netlist;
#   cdc_check.py lists every crossing, the instances of the library's CDC
#   modules in the sources being the synchronisers (--sync-src). (sv2v
#   inlines every module with interface ports into video_processor, 34k
#   lines Yosys's own front end needs hours for.) Results in build/cdc
#   (cdc_report.txt). The PLL oscillators (dpll_dco_bb, black boxes) register
#   their phase read-out on their reference clock (--bb-clock); the waivers
#   with their reasons are in synth/cdc_waivers.txt. Exit status 1 on an
#   unsynchronised crossing.
# Date: 2026-10-27
# ***************
# Usage: synth/run_cdc.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="$ROOT/../../ip"
OUT="$ROOT/build/cdc"; rm -rf "$OUT"; mkdir -p "$OUT"
command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }
grep -Ev '^\s*(#|$)' "$ROOT/scripts/build.f" | sed "s#^#$ROOT/#" > "$OUT/files.txt"
cat > "$OUT/cdc.ys" <<EOF
read_slang --single-unit --unroll-limit=200000 -D SYNTHESIS -G NPU_PE=8 --top video_processor $(tr '\n' ' ' < "$OUT/files.txt")
proc
flatten
opt_clean
memory -nomap
opt_clean
write_json $OUT/video_processor.json
EOF
cd "$OUT"
yosys -m slang -q -l yosys.log -s cdc.ys > /dev/null || { tail -5 yosys.log; echo "CDC CHECK FAIL (netlist)"; exit 1; }
python3 "$IP/scripts/cdc_check.py" "$OUT/video_processor.json" --top video_processor --sync-src "$OUT/files.txt" \
  --bb-clock dpll_dco_bb:phase_o=ref_clk --waive-file "$ROOT/synth/cdc_waivers.txt" --out "$OUT/cdc_report.txt"
