# ***************
# Filename: build.f
# Author: FPGA Cores 4 U
# Description: RTL source list for Yosys synthesis of this module,
# in dependency order (packages first). One path per line, relative
# to this directory. Lines starting with # are ignored.
# Date: September 26, 2026
# ***************
../../include/barrel_pkg.sv
../../include/distortion_model_pkg.sv
../fixed_recip/src/fixed_recip.sv
../mulq/src/mulq_s.sv
src/coord_gen.sv
