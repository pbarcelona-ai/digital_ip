#!/usr/bin/env bash
# Builds and runs bicubic's self-checking testbench.
# Depends on barrel_pkg.sv (for PIX_W and qmul()), in ../../rtl/, this
# project's shared package location.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o tb_bicubic.vvp \
  ../../rtl/barrel_pkg.sv bicubic.sv tb_bicubic.sv
vvp tb_bicubic.vvp
