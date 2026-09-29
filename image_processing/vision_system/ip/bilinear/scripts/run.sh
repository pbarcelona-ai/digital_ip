#!/usr/bin/env bash
# Builds and runs bilinear's self-checking testbench.
# Depends on barrel_pkg.sv (for PIX_W), in ../../src/, this project's
# shared package location.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")/.."

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 $DEFS -o tb_bilinear.vvp \
  ../../include/barrel_pkg.sv src/bilinear.sv tb/tb_bilinear.sv
vvp tb_bilinear.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
