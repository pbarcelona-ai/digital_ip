#!/usr/bin/env bash
# Fast smoke test: drives coord_gen.sv directly against the independent
# golden model for camera-calibration, tangential-distortion, and the
# fisheye/affine/perspective/scaling architecture-hook gate. Runs in
# seconds -- use this for a quick sanity check; use run.sh for the full
# 12-scenario image-streaming regression.
#
# Usage:
#   ./run_smoke.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o smoke.vvp \
  ppm_io_pkg.sv golden_model_pkg.sv \
  ../rtl/barrel_pkg.sv ../rtl/distortion_model_pkg.sv \
  ../ip/fixed_recip/fixed_recip.sv ../ip/coord_gen/coord_gen.sv \
  tb_smoke.sv

vvp smoke.vvp
