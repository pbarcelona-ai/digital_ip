// ***************
// Filename: configuration.sv
// Author: FPGA Cores 4 U
// Description: Build configuration of video_pipeline: which external
//   interfaces are included. Comment out a `define to exclude that interface;
//   its ports, logic and clocks disappear from video_pipeline, and its
//   registers read as 0. The BUILD_CFG register (0x0FC) reports the result.
//   This file must be compiled before video_pipeline.sv (it is the first
//   entry of scripts/build.f).
//     VP_CSI2_RX  MIPI CSI-2 camera input (D-PHY RX lanes, byte_clk). Without
//                 it the pipeline has no video source; the outputs can still
//                 show the test pattern.
//     VP_HDMI     HDMI / DVI output (TMDS symbols)
//     VP_LVDS     LVDS panel output (OpenLDI 7:1 words)
//     VP_DSI      MIPI DSI panel output (D-PHY TX lanes)
//     VP_CSI2_TX  MIPI CSI-2 output to a processor (D-PHY TX lanes)
//     VP_INSERT   AXI4-Stream insert point after isp_csc (ins_m_axis_* /
//                 ins_s_axis_*, CTRL[7]) for an external processing block
// Date: 2026-10-02
`ifndef VP_CONFIGURATION_SV
`define VP_CONFIGURATION_SV

`define VP_CSI2_RX
`define VP_HDMI
`define VP_LVDS
`define VP_DSI
`define VP_CSI2_TX
// `define VP_INSERT

// ---------------- derived (do not edit) ----------------
// tx_byte_clk is needed when either MIPI transmitter is built
`ifdef VP_DSI
  `define VP_MIPI_TX
`endif
`ifdef VP_CSI2_TX
  `ifndef VP_MIPI_TX
    `define VP_MIPI_TX
  `endif
`endif

`endif
