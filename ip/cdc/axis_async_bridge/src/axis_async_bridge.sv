// ***************
// Filename: axis_async_bridge.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream asynchronous clock domain bridge. Carries tdata,
//   tkeep, tlast and tuser from the slave clock domain to the master clock
//   domain through a gray pointer dual clock FIFO. Each side has an
//   independent active-low reset that is synchronized locally (async assert,
//   sync release). Optional depth for rate matching. Both resets should be
//   asserted together and held for at least 3 clocks of each domain. DATA_W
//   must be a multiple of 8 (tkeep has DATA_W / 8 bits). Version 1.0.0. Clocks - s_clk and m_clk unrelated,
//   built on async_fifo with the same crossing rules and latency (3 to 5
//   destination clocks). Reset - synchronous active low per domain. Timing -
//   see async_fifo. Errors - none at run time (full FIFO deasserts s_tready,
//   nothing is dropped); illegal parameters stop elaboration.
// Date: 2026-10-21
module axis_async_bridge #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 512,
  parameter int USER_W = 1
) (
  // Slave side
  input  logic                s_clk,
  input  logic                s_rst_n,
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W, USER_W = USER_W
  axis_if.slave s_axis,
  // Master side
  input  logic                m_clk,
  input  logic                m_rst_n,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W, USER_W = USER_W
  axis_if.master m_axis
);
  /* verilator lint_off UNUSEDPARAM */             // version identification (library convention), not logic
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  /* verilator lint_on UNUSEDPARAM */
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_chk_d $error("%m: DEPTH must be a power of two >= 4"); end
  if (DATA_W < 1) begin : g_chk_w $error("%m: DATA_W must be >= 1"); end
  if (DATA_W % 8 != 0) begin : g_chk_w8 $error("%m: DATA_W must be a multiple of 8 (tkeep)"); end

  localparam int W = DATA_W + DATA_W/8 + 1 + USER_W;

  // Local reset synchronizers: async assert, synchronous release
  logic [1:0] s_rs, m_rs;
  always_ff @(posedge s_clk or negedge s_rst_n)
    if (!s_rst_n) s_rs <= 2'b00;
    else s_rs <= {s_rs[0], 1'b1};
  always_ff @(posedge m_clk or negedge m_rst_n)
    if (!m_rst_n) m_rs <= 2'b00;
    else m_rs <= {m_rs[0], 1'b1};

  logic [W-1:0] wd, rd;
  logic wready, rvalid;
  logic [$clog2(DEPTH):0] wl;                     // FIFO level (not used)
  assign wd = {s_axis.tuser, s_axis.tlast, s_axis.tkeep, s_axis.tdata};
  assign s_axis.tready = wready & s_rs[1];

  async_fifo #(
    .DATA_W(W),
    .DEPTH(DEPTH)
  ) u_fifo (
    .wclk(s_clk),
    .wrst_n(s_rs[1]),
    .wdata(wd),
    .wvalid(s_axis.tvalid & s_rs[1]),
    .wready(wready),
    .wlevel_o(wl),
    .rclk(m_clk),
    .rrst_n(m_rs[1]),
    .rdata(rd),
    .rvalid(rvalid),
    .rready(m_axis.tready)
  );

  assign {m_axis.tuser, m_axis.tlast, m_axis.tkeep, m_axis.tdata} = rd;
  assign m_axis.tvalid = rvalid;
  wire unused_ok = &{1'b0, wl, 1'b0};
endmodule
