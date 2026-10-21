// ***************
// Filename: conv2d_core_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of conv2d_core for the comparison with its
//   model (conv2d_core_tb.py): the input stream as s_* ports, the output
//   as m_* ports, the frame size, kernel and shift, frame_o and sof_wait_o
//   as ports. Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module conv2d_core_cocotb_top #(
  parameter int N      = 5,
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 64,
  parameter int BORDER = 0
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic [15:0]           width_i,
  input  logic [15:0]           height_i,
  input  logic [N*N*COEF_W-1:0] coef_i,
  input  logic [4:0]            shift_i,
  input  logic [C*CW-1:0]       s_tdata,
  input  logic                  s_tvalid,
  output logic                  s_tready,
  input  logic                  s_tlast,
  input  logic                  s_tuser,
  output logic [C*CW-1:0]       m_tdata,
  output logic                  m_tvalid,
  input  logic                  m_tready,
  output logic                  m_tlast,
  output logic                  m_tuser,
  output logic                  frame_o,
  output logic                  sof_wait_o
);
  axis_if #(.DATA_W(C*CW)) si ();
  axis_if #(.DATA_W(C*CW)) mi ();
  assign si.tdata = s_tdata;
  assign si.tvalid = s_tvalid;
  assign s_tready = si.tready;
  assign si.tlast = s_tlast;
  assign si.tuser = s_tuser;
  assign si.tkeep = '1;
  assign m_tdata = mi.tdata;
  assign m_tvalid = mi.tvalid;
  assign mi.tready = m_tready;
  assign m_tlast = mi.tlast;
  assign m_tuser = mi.tuser;
  conv2d_core #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_dut (
    .clk,
    .rst_n,
    .width_i,
    .height_i,
    .coef_i,
    .shift_i,
    .s_axis(si),
    .m_axis(mi),
    .frame_o,
    .sof_wait_o
  );
  wire unused_ok = &{1'b0, si.tkeep, mi.tkeep, 1'b0};
endmodule
