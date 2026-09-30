// ***************
// Filename: axi_stream_fifo.sv
// Author: Paul Barcelona
// Description: AXI-Stream FIFO. Version 1.0.0. Buffers a full AXI-Stream
//   (tdata, tkeep, tlast, tuser) in a block-RAM FIFO of DEPTH beats with
//   standard valid/ready handshakes and a fill level. Built on
//   ip_axis_fifo (two-register output pipeline for timing). Clock - aclk.
//   Reset - synchronous aresetn, empty. Latency - 3 clocks from an input
//   beat to the output when empty. Throughput - one beat per clock.
//   Backpressure - s_axis_tready low when full; no data is ever dropped.
//   Errors - DEPTH must be a power of two >= 4 (rejected at elaboration);
//   USER_W >= 1.
// Date: 2026-09-29
module axi_stream_fifo #(
  parameter int DATA_W = 32,
  parameter int USER_W = 1,
  parameter int DEPTH  = 512
) (
  input  logic                    aclk,
  input  logic                    aresetn,
  input  logic [DATA_W-1:0]       s_axis_tdata,
  input  logic [DATA_W/8-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tlast,
  input  logic [USER_W-1:0]       s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  output logic [DATA_W-1:0]       m_axis_tdata,
  output logic [DATA_W/8-1:0]     m_axis_tkeep,
  output logic                    m_axis_tlast,
  output logic [USER_W-1:0]       m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic [$clog2(DEPTH)+1:0] level_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad $error("axi_stream_fifo: DEPTH must be a power of two >= 4"); end
  localparam int PW = DATA_W + DATA_W/8 + USER_W;
  logic [PW-1:0] pd, qd; logic mu;
  assign pd = {s_axis_tuser, s_axis_tkeep, s_axis_tdata};
  ip_axis_fifo #(.DATA_W(PW), .DEPTH(DEPTH)) u_fifo (
    .clk(aclk), .rst_n(aresetn), .s_tdata(pd), .s_tlast(s_axis_tlast), .s_tuser(1'b0), .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(qd), .m_tlast(m_axis_tlast), .m_tuser(mu), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready), .level_o(level_o));
  assign {m_axis_tuser, m_axis_tkeep, m_axis_tdata} = qd;
endmodule
