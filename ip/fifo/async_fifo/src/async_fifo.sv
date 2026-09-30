// ***************
// Filename: async_fifo.sv
// Author: Paul Barcelona
// Description: Dual clock (asynchronous) FIFO. Gray coded read and write
//   pointers cross domains through two flop synchronizers, full is generated
//   in the write domain and empty in the read domain. Storage is a dual clock
//   RAM (block RAM capable) with a registered read and a first-word-fall-
//   through output register. DEPTH must be a power of two >= 4. Assert both
//   resets together. Version 1.0.0. Clocks - wclk and rclk are unrelated
//   (Gray-coded pointers, two-flop synchronizers), each with its own
//   synchronous active low reset (reset both together). Latency - a written
//   word is visible on the read side 3 to 5 read clocks later; full/empty
//   flags are conservative, never optimistic. Timing - constrain the pointer
//   crossings with set_max_delay -datapath_only (or false path with skew
//   control); the memory read path is registered. Errors - writing when full
//   or reading when empty is ignored (and asserted in simulation); illegal
//   parameters stop elaboration. Clock - the clock of the parent block, all
//   signals are synchronous to it. Reset - synchronous, driven by the parent
//   block.
//   block.
// Date: 2026-09-29
module async_fifo #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 512
) (
  // Write domain
  input  logic              wclk,
  input  logic              wrst_n,
  input  logic [DATA_W-1:0] wdata,
  input  logic              wvalid,
  output logic              wready,       // not full
  output logic [$clog2(DEPTH):0] wlevel_o, // pessimistic fill level
  // Read domain
  input  logic              rclk,
  input  logic              rrst_n,
  output logic [DATA_W-1:0] rdata,
  output logic              rvalid,
  input  logic              rready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_chk_d $error("%m: DEPTH must be a power of two >= 4"); end
  if (DATA_W < 1) begin : g_chk_w $error("%m: DATA_W must be >= 1"); end

  localparam int AW = $clog2(DEPTH);
  logic [DATA_W-1:0] mem [0:DEPTH-1];

  // ---------------- write domain ----------------
  logic [AW:0] wbin, wgray, wbin_n, wgray_n;
  (* async_reg = "true" *) logic [AW:0] rgray_s1, rgray_s2;   // read gray in wclk
  logic wfull;
  wire  wen = wvalid & ~wfull;
  assign wbin_n  = wbin + {{AW{1'b0}}, wen};
  assign wgray_n = (wbin_n >> 1) ^ wbin_n;
  always_ff @(posedge wclk) begin
    if (!wrst_n) begin wbin <= '0; wgray <= '0; wfull <= 1'b0; end
    else begin
      wbin <= wbin_n; wgray <= wgray_n;
      // full: next write gray equals read gray with the two MSBs inverted
      wfull <= (wgray_n == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    end
  end
  always_ff @(posedge wclk) if (wen) mem[wbin[AW-1:0]] <= wdata;
  always_ff @(posedge wclk) begin
    if (!wrst_n) begin rgray_s1 <= '0; rgray_s2 <= '0; end
    else begin rgray_s1 <= rgray; rgray_s2 <= rgray_s1; end
  end
  assign wready = ~wfull;

  // ---------------- read domain ----------------
  logic [AW:0] rbin, rgray, rbin_n, rgray_n;
  (* async_reg = "true" *) logic [AW:0] wgray_s1, wgray_s2;   // write gray in rclk
  logic rempty;
  logic [DATA_W-1:0] mem_q, o_q; logic mem_q_vld, o_vld;
  wire move  = mem_q_vld & (~o_vld | rready);
  wire rd_en = ~rempty & (~mem_q_vld | move);
  assign rbin_n  = rbin + {{AW{1'b0}}, rd_en};
  assign rgray_n = (rbin_n >> 1) ^ rbin_n;
  always_ff @(posedge rclk) begin
    if (!rrst_n) begin
      rbin <= '0; rgray <= '0; rempty <= 1'b1; mem_q_vld <= 1'b0; o_vld <= 1'b0;
      wgray_s1 <= '0; wgray_s2 <= '0;
    end else begin
      wgray_s1 <= wgray; wgray_s2 <= wgray_s1;
      rbin <= rbin_n; rgray <= rgray_n;
      rempty <= (rgray_n == wgray_s2);
      mem_q_vld <= rd_en | (mem_q_vld & ~move);
      if (move) o_vld <= 1'b1; else if (o_vld & rready) o_vld <= 1'b0;
    end
  end
  always_ff @(posedge rclk) if (rd_en) mem_q <= mem[rbin[AW-1:0]];
  always_ff @(posedge rclk) if (move) o_q <= mem_q;
  assign rdata  = o_q;
  assign rvalid = o_vld;

  // Write side fill estimate from binary write pointer and synchronized read gray
  function automatic logic [AW:0] g2b(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW-1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    g2b = b;
  endfunction
  assign wlevel_o = wbin - g2b(rgray_s2);
endmodule
