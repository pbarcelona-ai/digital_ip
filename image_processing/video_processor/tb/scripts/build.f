# ***************
# Filename: build.f
# Author: FPGA Cores 4 U
# Description: Testbench source list of video_processor (compiled after
#   scripts/build.f), relative to the design directory. Board models come
#   are the shared bus functional models (ip/shared/tb/lib).
# Date: 2026-10-08
# ***************
../../ip/shared/tb/lib/lvds_bfm.sv
../../ip/shared/tb/lib/tmds_bfm.sv
../../ip/shared/tb/lib/uart_bfm.sv
../../ip/shared/tb/lib/axil_bfm.sv
../../ip/shared/tb/lib/i2c_bfm.sv
../../ip/shared/tb/lib/spi_flash_bfm.sv
../../ip/shared/tb/lib/csi2_bfm.sv
../../ip/shared/tb/lib/hdmi_bfm.sv
../../ip/video/video_tb_lib/conv2d_ref.sv
tb/video_processor_tb.sv
