// ***************
// Filename: scaler_polyphase.sv
// Author: FPGA Cores 4 U
// Description: Generic separable polyphase FIR scaler.
//   TAPS x TAPS kernel (even TAPS, 2..16) with programmable coefficient
//   tables. Engine of scaler_bicubic (4 taps) and scaler_lanczos (6 taps);
//   also usable directly, e.g. 8-12 taps for anti-aliased downscaling.
//   Source coordinate s (16.16) is rounded to PHASE_BITS fraction:
//     s_r = s + 2^(15-PHASE_BITS); i = s_r >>> 16; p = s_r[15 -: PB]
//   Window origin x0 = i - (TAPS/2 - 1), clamp-to-edge. With F=COEF_FRAC:
//     vertical   v_k = (sum_j CV[py][j]*in[y0+j][x0+k] + 2^(F-1)) >>> F
//     horizontal out = clamp((sum_k CH[px][k]*v_k + 2^(F-1)) >>> F)
//   IP registers:
//     0x040 COEF_INFO (RO) TAPS, PHASE_BITS, COEF_W, COEF_FRAC
//     0x1000 + 4*(16*phase + tap)  horizontal coefficients (RW, signed)
//     0x2000 + 4*(16*phase + tap)  vertical coefficients   (RW, signed)
//   Tables start as bilinear weights (initial block); update them only
//   while idle. See docs/coefficient_derivation.md.
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame (default
//   and PINGPONG = 1) or a few input lines (LINE_BUF = 1).
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_polyphase #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int TAPS       = 4,        // kernel size, even, 2..16
  parameter int PHASE_BITS = 6,        // log2(number of filter phases)
  parameter int COEF_W     = 16,       // coefficient width (signed)
  parameter int COEF_FRAC  = 14,       // coefficient fraction bits
  parameter logic [31:0] IP_ID = 32'h504F_4C59,              // "POLY"
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
