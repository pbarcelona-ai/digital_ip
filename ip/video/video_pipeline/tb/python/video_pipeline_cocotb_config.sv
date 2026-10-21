// ***************
// Filename: video_pipeline_cocotb_config.sv
// Author: FPGA Cores 4 U
// Description: build configuration of the video_pipeline cocotb test
//   (compiled before src/configuration.sv, whose include guard then skips
//   it): the CSI-2 receiver and the insert point only - the ISP output is
//   taken at the insert point; the display outputs are not built.
// Date: 2026-10-21
`ifndef VP_CONFIGURATION_SV
`define VP_CONFIGURATION_SV
`define VP_CSI2_RX
`define VP_INSERT
`endif
