#!/usr/bin/env bash
# Builds and runs bilinear's self-checking testbench.
# Depends on barrel_pkg.sv (for PIX_W), in ../../rtl/, this project's
# shared package location.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o tb_bilinear.vvp \
  ../../rtl/barrel_pkg.sv bilinear.sv tb_bilinear.sv
vvp tb_bilinear.vvp
