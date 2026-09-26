#!/usr/bin/env bash
# Builds and runs frame_buffer's self-checking testbench.
# Depends on barrel_pkg.sv (for default parameter values only -- all
# overridable, see frame_buffer.sv), which lives in ../../rtl/ as this
# project's shared package location.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o tb_frame_buffer.vvp \
  ../../rtl/vision_system_pkg.sv frame_buffer.sv tb_frame_buffer.sv
vvp tb_frame_buffer.vvp
