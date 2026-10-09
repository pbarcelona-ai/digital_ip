#!/usr/bin/env bash
# ***************
# Filename: run_test.sh
# Author: FPGA Cores 4 U
# Description: Compile tb/programs/selftest.py with pyc.py into a flash
#   image, then build and run the py_soc system testbench in iverilog twice:
#   a normal boot-and-run, and a boot from a corrupted image (+corrupt)
#   that must be rejected. Outputs (images, listing, logs, optional VCD) go
#   to build/sim/py_soc.
# Date: 2026-10-01
#
# Usage: scripts/run_test.sh [--vcd] [--wave]
#   --vcd   dump py_soc_tb.vcd (first run) in build/sim/py_soc
#   --wave  --vcd, then open it in the Surfer waveform viewer (pass or fail)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BUILD_ROOT:-$HERE/../../build}/sim/py_soc"; mkdir -p "$OUT"
cd "$HERE"
python3 ../py_core/tools/pyc.py tb/programs/selftest.py -o "$OUT/selftest"
iverilog -g2012 -Wno-timescale -s py_soc_tb -o "$OUT/py_soc_tb.vvp" -I "$OUT" -I tb/tests \
  -DPY_FLASH_HEX="\"$OUT/selftest.flash.hex\"" \
  -c scripts/build.f -c tb/scripts/build.f
ARGS=""; WAVE=0
for a in "$@"; do case "$a" in --vcd) ARGS="+vcd";; --wave) ARGS="+vcd"; WAVE=1;; *) echo "unknown option $a" >&2; exit 2;; esac; done
open_wave() {
  [ "$WAVE" = 1 ] || return 0
  if command -v surfer >/dev/null 2>&1; then echo "== opening $OUT/py_soc_tb.vcd in Surfer"; nohup surfer "$OUT/py_soc_tb.vcd" > "$OUT/surfer.log" 2>&1 &
  else echo "surfer not found; install from https://surfer-project.org and open $OUT/py_soc_tb.vcd"; fi
}
cd "$OUT"
echo "== boot and run"
vvp -n py_soc_tb.vvp $ARGS | tee py_soc_tb.log
open_wave
grep -q "TEST PASSED" py_soc_tb.log
echo "== corrupted flash image"
vvp -n py_soc_tb.vvp +corrupt | tee py_soc_tb_corrupt.log
grep -q "TEST PASSED" py_soc_tb_corrupt.log
