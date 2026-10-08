# ***************
# Filename: build.f
# Author: FPGA Cores 4 U
# Description: Testbench source list of video_processor (compiled after
#   scripts/build.f), relative to the design directory. Board models come
#   from the library testbenches.
# Date: 2026-10-08
# ***************
../../ip/shared/tb/lib/axil_bfm.sv
../../ip/peripherals/i2c_master/tb/i2c_master_tb.sv
../../ip/peripherals/spi_flash_ctrl/tb/spi_flash_ctrl_tb.sv
../../ip/video/video_tb_lib/csi2_lane_driver.sv
../../ip/video/video_tb_lib/hdmi_sink_model.sv
../../ip/video/video_tb_lib/conv2d_ref.sv
tb/video_processor_tb.sv
