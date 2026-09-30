// ***************
// Filename: axis_async_bridge.sv
// Author: Paul Barcelona
// Description: AXI-Stream asynchronous clock domain bridge. Carries tdata,
//   tkeep, tlast and tuser from the slave clock domain to the master clock
//   domain through a gray pointer dual clock FIFO. Each side has an
//   independent active-low reset that is synchronized locally (async assert,
//   sync release). Optional depth for rate matching. Both resets should be
//   asserted together. Version 1.0.0. Clocks - s_clk and m_clk unrelated,
//   built on async_fifo with the same crossing rules and latency (3 to 5
//   destination clocks). Reset - synchronous active low per domain. Timing -
//   see async_fifo. Errors - none at run time (full FIFO deasserts s_tready,
//   nothing is dropped); illegal parameters stop elaboration. Clock - the
//   clock of the parent block, all signals are synchronous to it. Latency -
//   as documented in the parent block, fixed and independent of data.
//   as documented in the parent block, fixed and independent of data.
// Date: 2026-09-29
module axis_async_bridge #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 512,
  parameter int USER_W = 1
) (
  // Slave side
  input  logic                s_clk,
  input  logic                s_rst_n,
  input  logic [DATA_W-1:0]   s_axis_tdata,
  input  logic [DATA_W/8-1:0] s_axis_tkeep,
  input  logic                s_axis_tlast,
  input  logic [USER_W-1:0]   s_axis_tuser,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  // Master side
  input  logic                m_clk,
  input  logic                m_rst_n,
  output logic [DATA_W-1:0]   m_axis_tdata,
  output logic [DATA_W/8-1:0] m_axis_tkeep,
  output logic                m_axis_tlast,
  output logic [USER_W-1:0]   m_axis_tuser,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_chk_d $error("%m: DEPTH must be a power of two >= 4"); end
  if (DATA_W < 1) begin : g_chk_w $error("%m: DATA_W must be >= 1"); end

  localparam int W = DATA_W + DATA_W/8 + 1 + USER_W;

  // Local reset synchronizers: async assert, synchronous release
  logic [1:0] s_rs, m_rs;
  always_ff @(posedge s_clk or negedge s_rst_n)
    if (!s_rst_n) s_rs <= 2'b00; else s_rs <= {s_rs[0], 1'b1};
  always_ff @(posedge m_clk or negedge m_rst_n)
    if (!m_rst_n) m_rs <= 2'b00; else m_rs <= {m_rs[0], 1'b1};

  logic [W-1:0] wd, rd; logic wready, rvalid;
  logic [$clog2(DEPTH):0] wl;
  assign wd = {s_axis_tuser, s_axis_tlast, s_axis_tkeep, s_axis_tdata};
  assign s_axis_tready = wready & s_rs[1];

  async_fifo #(.DATA_W(W), .DEPTH(DEPTH)) u_fifo (
    .wclk(s_clk), .wrst_n(s_rs[1]), .wdata(wd), .wvalid(s_axis_tvalid & s_rs[1]),
    .wready(wready), .wlevel_o(wl),
    .rclk(m_clk), .rrst_n(m_rs[1]), .rdata(rd), .rvalid(rvalid), .rready(m_axis_tready));

  assign {m_axis_tuser, m_axis_tlast, m_axis_tkeep, m_axis_tdata} = rd;
  assign m_axis_tvalid = rvalid;
endmodule
