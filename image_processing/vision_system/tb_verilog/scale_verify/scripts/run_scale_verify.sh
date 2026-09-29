#!/usr/bin/env bash
# Runs the large-frame (480x480 / 480x720 / 720x480) scale-verification
# suite. See README.md in this directory for what these tests are, why
# they're structured as full-completion vs. bounded-capture, and the
# results/bugs found the one time this was run in full.
#
# WARNING: this is SLOW. The six full-completion tests (bilinear+radial)
# take ~85-130s each (~11 minutes total); the four bounded-capture tests
# (bicubic, fisheye, panoramic, perspective) take ~200-215s each (~14
# minutes total). Budget at least 25 minutes to run everything below.
#
# Usage:
#   ./scripts/run_scale_verify.sh            # everything (~25 min)
#   ./scripts/run_scale_verify.sh fast       # just the 6 full-completion bilinear+radial tests (~11 min)
#   ./scripts/run_scale_verify.sh bounded    # just the 4 bounded-capture tests (~14 min)
set -e
cd "$(dirname "$0")/.."

MODE="${1:-all}"

build_and_run() {
  local src="$1"
  local vvp="/tmp/$(basename "$src" .sv).vvp"
  iverilog -g2012 -o "$vvp" \
    ../include/ppm_io_pkg.sv ../include/golden_model_pkg.sv \
    ../../include/barrel_pkg.sv ../../include/distortion_model_pkg.sv \
    ../../ip/fixed_recip/src/fixed_recip.sv ../../ip/mulq/src/mulq_s.sv ../../ip/coord_gen/src/coord_gen.sv \
    ../../ip/bilinear/src/bilinear.sv ../../ip/bicubic/src/bicubic.sv ../../ip/frame_buffer/src/frame_buffer.sv \
    ../../src/axis_in_ctrl.sv ../../src/axis_out_ctrl.sv ../../src/axi_lite_regs.sv \
    ../../src/vision_system.sv \
    "$src"
  vvp "$vvp"
}

if [ "$MODE" = "all" ] || [ "$MODE" = "fast" ]; then
  echo "=== full-completion bilinear+radial scenarios (true 480x480/720/720x480) ==="
  for f in tb_scale_barrel_square.sv tb_scale_barrel_portrait.sv tb_scale_barrel_landscape.sv \
           tb_scale_pincushion_square.sv tb_scale_pincushion_portrait.sv tb_scale_pincushion_landscape.sv; do
    build_and_run "$f"
  done
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "bounded" ]; then
  echo "=== bounded-capture scenarios (bicubic + fisheye/panoramic/perspective) ==="
  for f in tb_bounded_bicubic_radial.sv tb_bounded_fisheye.sv tb_bounded_panoramic.sv tb_bounded_perspective.sv; do
    build_and_run "$f"
  done
fi
