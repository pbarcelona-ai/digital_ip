# ***************
# Filename: build.f
# Author: Paul Barcelona
# Description: RTL source list for Yosys synthesis of this module,
# in dependency order (packages first). One path per line, relative
# to this directory. Lines starting with # are ignored.
# Date: September 26, 2026
# ***************
../../src/barrel_pkg.sv
../../src/distortion_model_pkg.sv
../fixed_recip/fixed_recip.sv
../mulq/mulq_s.sv
coord_gen.sv
