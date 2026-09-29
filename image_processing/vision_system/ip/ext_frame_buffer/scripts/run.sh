#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
iverilog -g2012 -s tb_ext_frame_buffer -o sim.vvp \
  ../../include/barrel_pkg.sv src/ext_frame_buffer.sv tb/tb_ext_frame_buffer.sv
vvp sim.vvp
rm -f sim.vvp