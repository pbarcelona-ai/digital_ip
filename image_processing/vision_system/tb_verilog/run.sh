#!/usr/bin/env bash
# ***************
# Filename: run.sh
# Author: Paul Barcelona
# Description: Builds and runs the pure-Verilog (no Python/cocotb)
# self-checking top-level testbench under Icarus Verilog. Options via
# environment: SMALL=1 uses small frames (fast, used by CI); VCD=1
# dumps waves.vcd (view with ../synth/view_waves.sh, i.e. Surfer).
# Date: September 26, 2026
# ***************
# Usage:
#   ./run.sh                 full-size frames (480x480 / 480x720 / 720x480)
#   SMALL=1 ./run.sh         small frames (48x48 / 32x56 / 56x32)
#   SMALL=1 VCD=1 ./run.sh   ... and write work/waves.vcd
set -e
cd "$(dirname "$0")"
mkdir -p work

DEFS=""
[ "${SMALL:-0}" = "1" ] && DEFS="$DEFS -DSMALL_FRAMES"
[ "${VCD:-0}" = "1" ]   && DEFS="$DEFS -DDUMP_VCD"

iverilog -g2012 $DEFS -o sim.vvp \
  ppm_io_pkg.sv golden_model_pkg.sv \
  ../src/barrel_pkg.sv ../src/distortion_model_pkg.sv \
  ../ip/fixed_recip/fixed_recip.sv ../ip/mulq/mulq_s.sv ../ip/coord_gen/coord_gen.sv \
  ../ip/bilinear/bilinear.sv ../ip/bicubic/bicubic.sv ../ip/frame_buffer/frame_buffer.sv \
  ../src/axis_in_ctrl.sv ../src/axis_out_ctrl.sv ../src/axi_lite_regs.sv \
  ../src/vision_system.sv \
  tb_vision_system.sv

vvp sim.vvp

if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../synth/view_waves.sh work/waves.vcd
fi
