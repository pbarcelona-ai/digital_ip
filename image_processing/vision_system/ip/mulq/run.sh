#!/usr/bin/env bash
# Builds and runs mulq_s's self-checking testbench (no package dependency).
set -e
cd "$(dirname "$0")"

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"
iverilog -g2012 $DEFS -o tb_mulq.vvp mulq_s.sv tb_mulq.sv
vvp tb_mulq.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
