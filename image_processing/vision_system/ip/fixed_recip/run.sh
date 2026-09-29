#!/usr/bin/env bash
# Builds and runs fixed_recip's self-checking testbench. No external
# package dependency -- this IP is fully standalone.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 $DEFS -o tb_fixed_recip.vvp fixed_recip.sv tb_fixed_recip.sv
vvp tb_fixed_recip.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
