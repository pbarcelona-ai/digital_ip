#!/usr/bin/env bash
# Builds and runs bicubic's self-checking testbench.
# Depends on barrel_pkg.sv (../../src/) and the mulq_s IP (../mulq/).
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")/.."

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 $DEFS -o tb_bicubic.vvp \
  ../../include/barrel_pkg.sv ../mulq/src/mulq_s.sv \
  src/bicubic.sv tb/tb_bicubic.sv
vvp tb_bicubic.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
