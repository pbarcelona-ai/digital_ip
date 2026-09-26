#!/usr/bin/env bash
# Builds and runs the pure-Verilog (no Python/cocotb) self-checking
# testbench under Icarus Verilog.
#
# Usage:
#   ./run.sh
#
# Drop your own work/test.ppm in first to correct a specific image;
# otherwise a synthetic grid/circle test chart is generated automatically.
# Produces work/{warped,corrected}.ppm and prints PASS/FAIL.
set -e
cd "$(dirname "$0")"
mkdir -p work

iverilog -g2012 -o sim.vvp \
  ppm_io_pkg.sv golden_model_pkg.sv \
  ../rtl/barrel_pkg.sv ../rtl/distortion_model_pkg.sv \
  ../ip/fixed_recip/fixed_recip.sv ../ip/coord_gen/coord_gen.sv \
  ../ip/bilinear/bilinear.sv ../ip/bicubic/bicubic.sv ../ip/frame_buffer/frame_buffer.sv \
  ../rtl/axis_in_ctrl.sv ../rtl/axis_out_ctrl.sv ../rtl/axi_lite_regs.sv \
  ../rtl/lens_distortion_correction.sv \
  tb_lens_distortion_correction.sv

vvp sim.vvp
