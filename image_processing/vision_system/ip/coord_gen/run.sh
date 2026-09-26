#!/usr/bin/env bash
# Builds and runs coord_gen's self-checking testbench.
# Depends on barrel_pkg.sv and distortion_model_pkg.sv, in ../../rtl/,
# this project's shared package location, plus fixed_recip.sv (the
# MODEL_FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE "slow path" instantiates
# it directly -- see coord_gen.sv), in the sibling ip/fixed_recip/ IP.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o tb_coord_gen.vvp \
  ../../rtl/barrel_pkg.sv ../../rtl/distortion_model_pkg.sv \
  ../fixed_recip/fixed_recip.sv \
  coord_gen.sv tb_coord_gen.sv
vvp tb_coord_gen.vvp
