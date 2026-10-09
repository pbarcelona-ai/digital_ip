#!/usr/bin/env bash
# Fast smoke test: drives coord_gen.sv directly against the independent
# golden model for camera-calibration, tangential-distortion, and the
# fisheye/affine/perspective/scaling architecture-hook gate. Runs in
# seconds -- use this for a quick sanity check; use scripts/run.sh for the full
# 12-scenario image-streaming regression.
#
# Usage:
#   ./scripts/run_smoke.sh
set -e
cd "$(dirname "$0")/.."

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 -I tests $DEFS -o smoke.vvp \
  include/ppm_io_pkg.sv include/golden_model_pkg.sv \
  ../include/barrel_pkg.sv ../include/distortion_model_pkg.sv \
  ../ip/fixed_recip/src/fixed_recip.sv ../ip/mulq/src/mulq_s.sv ../ip/coord_gen/src/coord_gen.sv \
  tb_smoke.sv

vvp smoke.vvp

# Optional waveform viewing: VCD=1 dumps waves.vcd; SURFER=1 opens it.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../synth/view_waves.sh waves.vcd
fi
