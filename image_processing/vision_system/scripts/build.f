# ***************
# Filename: build.f
# Author: FPGA Cores 4 U
# Description: RTL source list for Yosys synthesis of this module,
# in dependency order (packages first). One path per line, relative
# to this directory. Lines starting with # are ignored.
# Date: September 26, 2026
# ***************
../include/barrel_pkg.sv
../include/distortion_model_pkg.sv
../ip/fixed_recip/src/fixed_recip.sv
../ip/mulq/src/mulq_s.sv
../ip/coord_gen/src/coord_gen.sv
../ip/bilinear/src/bilinear.sv
../ip/bicubic/src/bicubic.sv
../ip/frame_buffer/src/frame_buffer.sv
../ip/ext_frame_buffer/src/ext_frame_buffer.sv
axis_in_ctrl.sv
axis_out_ctrl.sv
axi_lite_regs.sv
vision_system.sv
