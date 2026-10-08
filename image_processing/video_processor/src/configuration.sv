// ***************
// Filename: configuration.sv
// Author: FPGA Cores 4 U
// Description: Build configuration of video_processor: which external
//   interfaces are included. Comment out a `define to exclude that interface;
//   its ports, serializer, logic and clock inputs disappear from
//   video_processor and video_pipeline, and its registers read as 0. The
//   BUILD_CFG register (0x0FC) reports the result. This file replaces the
//   library default (ip/video/video_pipeline/src/configuration.sv) for this
//   design and must be compiled first (first entry of scripts/build.f).
//     VP_CSI2_RX  MIPI CSI-2 camera input (D-PHY RX lanes, byte_clk). Without
//                 it the pipeline has no video source; the outputs can still
//                 show the test pattern.
//     VP_HDMI     HDMI / DVI output (TMDS symbols)
//     VP_LVDS     LVDS panel output (OpenLDI 7:1 words)
//     VP_DSI      MIPI DSI panel output (D-PHY TX lanes)
//     VP_CSI2_TX  MIPI CSI-2 output to a processor (D-PHY TX lanes)
//     VP_VISION   vision_system lens-distortion correction at the
//                 video_pipeline insert point (implies VP_INSERT)
//     VP_FILTER   blur_sharpen (blur / sharpen, 4 modes) in the insert loop,
//                 after vision_system (implies VP_INSERT)
//     VP_INSERT   video_pipeline insert point only (looped back here)
// Date: 2026-10-02
`ifndef VP_CONFIGURATION_SV
`define VP_CONFIGURATION_SV

`define VP_CSI2_RX
`define VP_HDMI
`define VP_LVDS
`define VP_DSI
`define VP_CSI2_TX
`define VP_VISION
`define VP_FILTER

// ---------------- derived (do not edit) ----------------
`ifdef VP_VISION
  `ifndef VP_INSERT
    `define VP_INSERT
  `endif
`endif
`ifdef VP_FILTER
  `ifndef VP_INSERT
    `define VP_INSERT
  `endif
`endif
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
