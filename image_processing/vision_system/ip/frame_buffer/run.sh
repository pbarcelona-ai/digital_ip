#!/usr/bin/env bash
# Builds and runs frame_buffer's self-checking testbench.
# Depends on barrel_pkg.sv (for default parameter values only -- all
# overridable, see frame_buffer.sv), which lives in ../../src/ as this
# project's shared package location.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 $DEFS -o tb_frame_buffer.vvp \
  ../../src/barrel_pkg.sv frame_buffer.sv tb_frame_buffer.sv
vvp tb_frame_buffer.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
