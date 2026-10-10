// ***************
// Filename: sharpen_filter.sv
// Author: FPGA Cores 4 U
// Description: Sharpening filter for AXI4-Stream video. Version 1.0.0.
//   conv2d_filter whose reset kernel is an unsharp mask:
//   (1 + AMOUNT) x identity - AMOUNT x blur, sum 1.0 (flat areas keep their
//   level, edges and detail are amplified).
//   The kernel and SHIFT stay programmable over AXI4-Lite (same register
//   map as conv2d_filter, ID "SHRP"): e.g. a 3 x 3 kernel inside the 5 x 5
//   for a finer sharpen, or another strength. FRAME_SIZE must match the
//   video. Clock - clk. Reset - synchronous rst_n (active low).
// Date: 2026-10-08
module sharpen_filter #(
  parameter int N      = 5,                        // kernel size: 3 or 5
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 2048,
  parameter int BORDER = 0,
  parameter int AMOUNT = 1,                        // sharpening strength (integer)
  parameter logic [15:0] RESET_W = 16'd1920,
  parameter logic [15:0] RESET_H = 16'd1080
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [7:0]         s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [7:0]         s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  input  logic [C*CW-1:0]    s_axis_tdata,
  input  logic               s_axis_tlast,
  input  logic               s_axis_tuser,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  output logic [C*CW-1:0]    m_axis_tdata,
  output logic               m_axis_tlast,
  output logic               m_axis_tuser,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready
);
  conv2d_filter #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER),
    .ID(32'h5348_5250),
    .KERNEL(conv2d_pkg::sharpen_kernel(N, AMOUNT)),
    .SHIFT(conv2d_pkg::blur_shift(N)),
    .RESET_W(RESET_W),
    .RESET_H(RESET_H)
  ) u_filter (.*);
endmodule
