// ***************
// Filename: scaler_lanczos.sv
// Author: FPGA Cores 4 U
// Description: Lanczos-3 (6x6) image scaler IP.
//   Thin wrapper around scaler_polyphase with TAPS = 6. Coefficients are
//   L(x) = sinc(x)*sinc(x/3), |x| < 3, sampled per phase, normalised to
//   unity DC gain and quantised (tools/scaler_coefs.py --kernel lanczos
//   --a 3). Lanczos-2 tables also fit (outer taps zero). Overshoot of the
//   negative lobes is clamped to the component range at the output.
//   Registers: common map (scaler_ctrl) + scaler_polyphase (0x040,
//   0x1000 H table, 0x2000 V table). IP_ID = "LANC".
//   Uses: scaler_polyphase, axil_regbus, scaler_ctrl, scaler_dda,
//   banked_framebuf.
// Date: 2026-09-26

module scaler_lanczos #(
  parameter int CHANNELS   = 3,        // components per pixel
  parameter int COMP_W     = 8,        // bits per component
  parameter int MAX_W      = 1920,     // frame buffer width
  parameter int MAX_H      = 1080,     // frame buffer height
  parameter int ADDR_W     = 14,       // AXI-Lite address width
  parameter int PHASE_BITS = 6,        // log2(number of filter phases)
  parameter int COEF_W     = 16,       // coefficient width (signed)
  parameter int COEF_FRAC  = 14,       // coefficient fraction bits
  parameter int PINGPONG   = 0,        // 1: double frame buffer
  parameter int LINE_BUF   = 0,        // 1: line-buffer mode (few lines of latency)
  localparam int PIX_W     = CHANNELS * COMP_W // bits per pixel
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

  // All logic is in scaler_polyphase; this wrapper fixes TAPS = 6 and
  // the IP_ID. Every port is connected by name (.*).
  scaler_polyphase #(
    .PINGPONG(PINGPONG),
    .LINE_BUF(LINE_BUF),
    .CHANNELS(CHANNELS),
    .COMP_W(COMP_W),
    .MAX_W(MAX_W),
    .MAX_H(MAX_H),
    .ADDR_W(ADDR_W),
    .TAPS(6),
    .PHASE_BITS(PHASE_BITS),
    .COEF_W(COEF_W),
    .COEF_FRAC(COEF_FRAC),
    .IP_ID(32'h4C41_4E43) // "LANC"
  ) u_core (.*);

endmodule
