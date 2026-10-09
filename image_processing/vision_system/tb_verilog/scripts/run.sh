#!/usr/bin/env bash
# ***************
# Filename: run.sh
# Author: FPGA Cores 4 U
# Description: Builds and runs the pure-Verilog (no Python/cocotb)
# self-checking top-level testbench under Icarus Verilog. Options via
# environment: SMALL=1 uses small frames (fast, used by CI); VCD=1
# dumps waves.vcd (view with ../synth/view_waves.sh, i.e. Surfer).
# Date: September 26, 2026
# ***************
# Usage:
#   ./scripts/run.sh                 full-size frames (480x480 / 480x720 / 720x480)
#   SMALL=1 ./scripts/run.sh         small frames (48x48 / 32x56 / 56x32)
#   SMALL=1 VCD=1 ./scripts/run.sh   ... and write work/waves.vcd
set -e
cd "$(dirname "$0")/.."
mkdir -p work
RUN_ARGS=()
if [ "${SMALL:-0}" = "1" ]; then
  mkdir -p work_small
  RUN_ARGS+=(+WORK_DIR=work_small)
fi

DEFS=""
[ "${SMALL:-0}" = "1" ] && DEFS="$DEFS -DSMALL_FRAMES"
[ "${VCD:-0}" = "1" ]   && DEFS="$DEFS -DDUMP_VCD"

iverilog -g2012 -I tests $DEFS -o sim.vvp \
  include/ppm_io_pkg.sv include/golden_model_pkg.sv \
  ../include/barrel_pkg.sv ../include/distortion_model_pkg.sv \
  ../ip/fixed_recip/src/fixed_recip.sv ../ip/mulq/src/mulq_s.sv ../ip/coord_gen/src/coord_gen.sv \
  ../ip/bilinear/src/bilinear.sv ../ip/bicubic/src/bicubic.sv ../ip/frame_buffer/src/frame_buffer.sv \
  ../ip/ext_frame_buffer/src/ext_frame_buffer.sv \
  ../src/axis_in_ctrl.sv ../src/axis_out_ctrl.sv ../src/axi_lite_regs.sv \
  ../src/vision_system.sv \
  tb_vision_system.sv

vvp sim.vvp "${RUN_ARGS[@]}"

if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../synth/view_waves.sh work/waves.vcd
fi
