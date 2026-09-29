# ***************
# Filename: build.f
# Author: Paul Barcelona
# Description: RTL source list for Yosys synthesis of this module,
# in dependency order (packages first). One path per line, relative
# to this directory. Lines starting with # are ignored.
# Date: September 26, 2026
# ***************
barrel_pkg.sv
distortion_model_pkg.sv
../ip/fixed_recip/fixed_recip.sv
../ip/mulq/mulq_s.sv
../ip/coord_gen/coord_gen.sv
../ip/bilinear/bilinear.sv
../ip/bicubic/bicubic.sv
../ip/frame_buffer/frame_buffer.sv
axis_in_ctrl.sv
axis_out_ctrl.sv
axi_lite_regs.sv
vision_system.sv
