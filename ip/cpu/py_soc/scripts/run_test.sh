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
# Usage: scripts/run_test.sh [--vcd]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BUILD_ROOT:-$HERE/../../build}/sim/py_soc"; mkdir -p "$OUT"
cd "$HERE"
python3 ../py_core/tools/pyc.py tb/programs/selftest.py -o "$OUT/selftest"
iverilog -g2012 -Wno-timescale -s py_soc_tb -o "$OUT/py_soc_tb.vvp" -I "$OUT" \
  -DPY_FLASH_HEX="\"$OUT/selftest.flash.hex\"" \
  -c scripts/build.f -c tb/scripts/build.f
ARGS=""; [ "${1:-}" = "--vcd" ] && ARGS="+vcd"
cd "$OUT"
echo "== boot and run"
vvp -n py_soc_tb.vvp $ARGS | tee py_soc_tb.log
grep -q "TEST PASSED" py_soc_tb.log
echo "== corrupted flash image"
vvp -n py_soc_tb.vvp +corrupt | tee py_soc_tb_corrupt.log
grep -q "TEST PASSED" py_soc_tb_corrupt.log
