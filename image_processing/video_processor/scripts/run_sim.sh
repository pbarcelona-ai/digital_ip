#!/usr/bin/env bash
# ***************
# Filename: run_sim.sh
# Author: FPGA Cores 4 U
# Description: Compile the firmware (sw/video_init.py -> build/fw, pyc.py)
#   and run the video_processor system testbench with Icarus Verilog.
#   Sources: scripts/build.f then tb/scripts/build.f. Output goes to
#   build/sim. Fails unless the log contains TEST PASSED.
# Date: 2026-10-02
# ***************
# Usage: scripts/run_sim.sh [--vcd] [--lint]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filelist() { grep -Ev '^\s*(#|$)' "$ROOT/$1" | sed "s#^#$ROOT/#"; }
VCD=0; LINT=0
for a in "$@"; do
  case "$a" in --vcd) VCD=1;; --lint) LINT=1;; *) echo "unknown option $a"; exit 2;; esac
done
SRCS="$(filelist scripts/build.f | tr '\n' ' ')"
TB_SRCS="$(filelist tb/scripts/build.f | tr '\n' ' ')"
if [ "$LINT" = 1 ]; then
  verilator --lint-only -Wall -Wno-fatal --top-module video_processor $SRCS
fi
FW="$ROOT/build/fw"; mkdir -p "$FW"
python3 "$ROOT/../../ip/cpu/py_core/tools/pyc.py" "$ROOT/sw/video_init.py" -o "$FW/video_init"
OUT="$ROOT/build/sim"; mkdir -p "$OUT"; cd "$OUT"
iverilog -g2012 -Wall -Wno-timescale -s video_processor_tb -o video_processor_tb.vvp -I "$FW" \
  -DFW_HEX="\"$FW/video_init.flash.hex\"" $SRCS $TB_SRCS
ARGS=""; [ "$VCD" = 1 ] && ARGS="+vcd"
vvp -n video_processor_tb.vvp $ARGS | tee video_processor_tb.log
grep -q "TEST PASSED" video_processor_tb.log || { echo "[video_processor] SIMULATION FAILED"; exit 1; }
echo "[video_processor] PASSED"
