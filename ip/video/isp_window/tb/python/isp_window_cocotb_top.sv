// ***************
// Filename: isp_window_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of isp_window for the comparison with its
//   model (isp_window_tb.py): the input stream as s_* ports, the windows as
//   m_* ports with m_x / m_y, the frame size and sof_wait_o as ports.
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module isp_window_cocotb_top #(
  parameter int N      = 3,
  parameter int PW     = 10,
  parameter int MAX_W  = 64,
  parameter int BORDER = 0
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [15:0]       width_i,
  input  logic [15:0]       height_i,
  input  logic [PW-1:0]     s_tdata,
  input  logic              s_tvalid,
  output logic              s_tready,
  input  logic              s_tlast,
  input  logic              s_tuser,
  output logic [N*N*PW-1:0] m_tdata,
  output logic              m_tvalid,
  input  logic              m_tready,
  output logic              m_tlast,
  output logic              m_tuser,
  output logic [15:0]       m_x,
  output logic [15:0]       m_y,
  output logic              sof_wait_o
);
  axis_if #(.DATA_W(PW)) si ();
  axis_if #(.DATA_W(N*N*PW)) mi ();
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
  isp_window #(
    .N(N),
    .PW(PW),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_dut (
    .clk,
    .rst_n,
    .width_i,
    .height_i,
    .s_axis(si),
    .m_axis(mi),
    .m_x,
    .m_y,
    .sof_wait_o
  );
  wire unused_ok = &{1'b0, si.tkeep, mi.tkeep, 1'b0};
endmodule
