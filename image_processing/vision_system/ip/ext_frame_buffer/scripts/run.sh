#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional waveform viewing: VCD=1 dumps waves.vcd; SURFER=1 opens it (../../synth/view_waves.sh).
DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"
iverilog -g2012 -I tb/tests $DEFS -s tb_ext_frame_buffer -o sim.vvp \
  ../../include/barrel_pkg.sv src/ext_frame_buffer.sv tb/tb_ext_frame_buffer.sv
vvp sim.vvp
rm -f sim.vvp
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi