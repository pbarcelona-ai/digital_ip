// ***************
// Filename: scaler_bilinear.sv
// Author: FPGA Cores 4 U
// Description: Bilinear (2x2) image scaler IP.
//   The 16.16 source coordinate s is rounded to PB = PHASE_BITS bits:
//     s_r = s + 2^(15-PB); i = s_r >>> 16; f = s_r[15 -: PB]
//   With ONE = 2^PHASE_BITS and taps p00 p01 / p10 p11 at (i, i+1):
//     top = p00*(ONE-fx) + p01*fx
//     bot = p10*(ONE-fx) + p11*fx
//     out = (top*(ONE-fy) + bot*fy + ONE^2/2) >> (2*PHASE_BITS)
//   Weights are computed in hardware; no coefficient tables.
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame (default
//   and PINGPONG = 1) or a few input lines (LINE_BUF = 1).
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_bilinear #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int PHASE_BITS = 8,        // sub-pixel phase resolution
  parameter int PINGPONG = 0,          // 1: double frame buffer (capture while generating)
  parameter int LINE_BUF = 0,          // 1: line-buffer mode (latency of a few lines;
                                       //    MAX_H is then not a limit, STEP_Y >= 0)
  localparam int PIX_W   = CHANNELS * COMP_W   // bits per pixel
)(
  input  logic              clk,            // clock
  input  logic              rst_n,          // async reset, active low
  // AXI4-Lite control slave (register map in the file header)
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // AXI4-Stream video in (raster order)
  input  logic [PIX_W-1:0]  s_axis_tdata,   // pixel, component 0 in LSBs
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,  // low while generating
  input  logic              s_axis_tuser,   // start of frame
  input  logic              s_axis_tlast,   // end of line
  // AXI4-Stream video out (raster order)
  output logic [PIX_W-1:0]  m_axis_tdata,   // scaled pixel
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,  // back-pressure stalls all
  output logic              m_axis_tuser,   // start of frame
  output logic              m_axis_tlast    // end of line
);
