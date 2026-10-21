// ***************
// Filename: ip_axis_fifo_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of ip_axis_fifo (ip_axis_fifo_tb.py compares it
//   with the golden model ip/shared/model/ip_axis_fifo_model.py): the FIFO
//   with its AXI-Stream ports flattened (8-bit data, tlast, 1-bit tuser) and
//   its level. Clock - clk. Reset - synchronous active low rst_n.
// Date: 2026-10-20
// ***************
module ip_axis_fifo_cocotb_top #(
  parameter int DEPTH = 4
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [7:0]               s_tdata,
  input  logic                     s_tlast,
  input  logic                     s_tuser,
  input  logic                     s_tvalid,
  output logic                     s_tready,
  output logic [7:0]               m_tdata,
  output logic                     m_tlast,
  output logic                     m_tuser,
  output logic                     m_tvalid,
  input  logic                     m_tready,
  output logic [$clog2(DEPTH)+1:0] level
);
  axis_if #(.DATA_W(8)) s ();
  axis_if #(.DATA_W(8)) m ();
  assign s.tdata = s_tdata;
  assign s.tlast = s_tlast;
  assign s.tuser = s_tuser;
  assign s.tkeep = 1'b1;
  assign s.tvalid = s_tvalid;
  assign s_tready = s.tready;
  assign m_tdata = m.tdata;
  assign m_tlast = m.tlast;
  assign m_tuser = m.tuser;
  assign m_tvalid = m.tvalid;
  assign m.tready = m_tready;
  wire unused_keep = &{1'b0, m.tkeep};                         // byte stream: tkeep constant
  ip_axis_fifo #(.DATA_W(8), .DEPTH(DEPTH)) u_fifo (
    .clk,
    .rst_n,
    .s(s),
    .m(m),
    .level_o(level)
  );
endmodule
