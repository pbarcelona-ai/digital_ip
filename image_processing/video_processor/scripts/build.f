# ***************
# Filename: build.f
# Author: FPGA Cores 4 U
# Description: RTL source list of video_processor in dependency order, one
#   path per line relative to the design directory (image_processing/
#   video_processor). Lines starting with # are ignored. src/configuration.sv
#   is first: it selects the external interfaces (it replaces the library
#   default ip/video/video_pipeline/src/configuration.sv, which is NOT listed).
# Date: 2026-10-02
# ***************
src/configuration.sv
# ---- shared / CDC
../../ip/cdc/reset_sync/src/reset_sync.sv
../../ip/cdc/axi4_lite_cdc/src/cdc_sync_bit.sv
../../ip/cdc/axi4_lite_cdc/src/axi4_lite_cdc.sv
# ---- py_soc (control CPU)
../../ip/cpu/py_core/src/py_core_pkg.sv
../../ip/cpu/py_core/src/py_core.sv
../../ip/bus/axi4_lite_slave/src/axi4_lite_slave.sv
../../ip/bus/axi4_lite_decoder/src/axi4_lite_decoder.sv
../../ip/peripherals/uart/src/uart_baud.sv
../../ip/peripherals/uart/src/uart_tx.sv
../../ip/peripherals/uart/src/uart_rx.sv
../../ip/peripherals/uart/src/uart_top.sv
../../ip/peripherals/i2c_master/src/i2c_bit_ctrl.sv
../../ip/peripherals/i2c_master/src/i2c_master_fsm.sv
../../ip/peripherals/i2c_master/src/i2c_top.sv
../../ip/peripherals/spi_master/src/spi_engine.sv
../../ip/peripherals/spi_master/src/spi_top.sv
../../ip/peripherals/gpio/src/gpio_top.sv
../../ip/peripherals/intc/src/intc_top.sv
../../ip/timing/watchdog/src/watchdog_top.sv
../../ip/cpu/py_soc/src/py_stream_port.sv
../../ip/cpu/py_soc/src/py_axil_xbar.sv
../../ip/peripherals/spi_flash_ctrl/src/spi_flash_ctrl.sv
../../ip/cpu/py_soc/src/py_boot.sv
../../ip/cpu/py_soc/src/py_sysctl.sv
../../ip/cpu/py_soc/src/py_soc.sv
# ---- video_pipeline
../../ip/shared/src/common/ip_axil_regs.sv
../../ip/shared/src/fifo/ip_axis_fifo.sv
../../ip/fifo/async_fifo/src/async_fifo.sv
../../ip/cdc/axis_async_bridge/src/axis_async_bridge.sv
../../ip/cdc/bit_sync/src/bit_sync.sv
../../ip/cdc/pulse_sync/src/pulse_sync.sv
../../ip/scalers/axil_split/src/axil_split.sv
../../ip/scalers/axil_regbus/src/axil_regbus.sv
../../ip/scalers/scaler_ctrl/src/scaler_ctrl.sv
../../ip/scalers/scaler_dda/src/scaler_dda.sv
../../ip/scalers/banked_framebuf/src/banked_framebuf.sv
../../ip/scalers/scaler_bilinear/src/scaler_bilinear.sv
../../ip/video/csi2_rx/src/csi2_rx.sv
../../ip/video/csi2_raw_unpack/src/csi2_raw_unpack.sv
../../ip/video/isp_window/src/isp_window.sv
../../ip/video/isp_blc_wb/src/isp_blc_wb.sv
../../ip/video/isp_dpc/src/isp_dpc.sv
../../ip/video/isp_demosaic/src/isp_demosaic.sv
../../ip/video/isp_ccm/src/isp_ccm.sv
../../ip/video/isp_gamma/src/isp_gamma.sv
../../ip/video/isp_csc/src/isp_csc.sv
../../ip/video/isp_stats/src/isp_stats.sv
../../ip/video/vid_timing_gen/src/vid_timing_gen.sv
../../ip/video/axis_to_video/src/axis_to_video.sv
../../ip/video/tmds_encoder/src/tmds_encoder.sv
../../ip/video/hdmi_tx/src/hdmi_tx.sv
../../ip/video/mipi_line_buf/src/mipi_line_buf.sv
../../ip/video/mipi_tx_engine/src/mipi_tx_engine.sv
../../ip/video/csi2_tx/src/csi2_tx.sv
../../ip/video/dsi_tx/src/dsi_tx.sv
../../ip/video/lvds_tx/src/lvds_tx.sv
../../ip/video/video_pipeline/src/video_pipeline.sv
../../ip/video/tmds_serializer/src/tmds_serializer.sv
../../ip/video/lvds_serializer/src/lvds_serializer.sv
# ---- vision_system
../vision_system/include/barrel_pkg.sv
../vision_system/include/distortion_model_pkg.sv
../vision_system/ip/fixed_recip/src/fixed_recip.sv
../vision_system/ip/mulq/src/mulq_s.sv
../vision_system/ip/coord_gen/src/coord_gen.sv
../vision_system/ip/bilinear/src/bilinear.sv
../vision_system/ip/bicubic/src/bicubic.sv
../vision_system/ip/frame_buffer/src/frame_buffer.sv
../vision_system/ip/ext_frame_buffer/src/ext_frame_buffer.sv
../vision_system/src/axis_in_ctrl.sv
../vision_system/src/axis_out_ctrl.sv
../vision_system/src/axi_lite_regs.sv
../vision_system/src/vision_system.sv
# ---- blur_sharpen
../../ip/video/conv2d_core/src/conv2d_pkg.sv
../../ip/video/conv2d_core/src/conv2d_core.sv
../../ip/video/blur_sharpen/src/blur_sharpen.sv
# ---- video_processor
src/vs_stream_adapter.sv
src/frame_counter.sv
src/video_processor.sv
