// ***************
// Filename: video_pipeline_map_pkg.sv
// Author: FPGA Cores 4 U
// Description: Memory map of video_pipeline's AXI4-Lite interface (pixel
//   clock domain, ADDR_W = 15): its own register map and the scaler's,
//   separated by address bit SPLIT_BIT (axil_split). video_pipeline's split,
//   its testbench and the map packages of the designs around it (e.g.
//   video_processor_map_pkg, read by the firmware through pyc.py) take the
//   offsets from this file.
// Date: 2026-10-21
package video_pipeline_map_pkg;
  localparam int          ADDR_W      = 15;
  localparam int          SPLIT_BIT   = 14;              // 0: pipeline registers, 1: scaler
  /* verilator lint_off UNUSEDPARAM */             // the map for the designs around (their map packages)
  localparam logic [31:0] VPIP_OFFSET = 32'h0000_0000;   // video_pipeline_regs (ID "VPIP")
  localparam logic [31:0] VPIP_SIZE   = 32'h0000_4000;
  localparam logic [31:0] SCALER_OFFSET = 32'h0000_4000; // scaler_bilinear (scaler_ctrl map, ID "BLIN")
  localparam logic [31:0] SCALER_SIZE = 32'h0000_4000;
  /* verilator lint_on UNUSEDPARAM */
endpackage
