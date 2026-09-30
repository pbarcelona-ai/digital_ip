// ***************
// Filename: sync_fifo.sv
// Author: Paul Barcelona
// Description: Synchronous FIFO with registered read (standard mode).
//   Version 1.0.0. Write with wr_en_i, read with rd_en_i; read data is
//   valid the clock after rd_en_i (rd_valid_o marks it). Full/empty flags,
//   level, programmable almost-full and almost-empty thresholds, sticky
//   overflow/underflow error flags (cleared by clr_err_i). Overflowing
//   writes and underflowing reads are ignored so state is never corrupted.
//   Clock - single clk. Reset - synchronous active low, FIFO empty, flags
//   cleared. Latency - write to empty deassert 1 clock; read 1 clock.
//   Storage - inferred RAM (block RAM for large depths). Errors - DEPTH
//   must be a power of two >= 4 (rejected at elaboration).
// Date: 2026-09-29
module sync_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 512
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     wr_en_i,
  input  logic [WIDTH-1:0]         wdata_i,
  input  logic                     rd_en_i,
  output logic [WIDTH-1:0]         rdata_o,
  output logic                     rd_valid_o,
  output logic                     full_o,
  output logic                     empty_o,
  output logic [$clog2(DEPTH):0]   level_o,
  input  logic [$clog2(DEPTH):0]   afull_thresh_i,    // almost_full when level >= thresh
  input  logic [$clog2(DEPTH):0]   aempty_thresh_i,   // almost_empty when level <= thresh
  output logic                     almost_full_o,
  output logic                     almost_empty_o,
  input  logic                     clr_err_i,
  output logic                     overflow_o,        // sticky
  output logic                     underflow_o        // sticky
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int AW = $clog2(DEPTH);
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad $error("sync_fifo: DEPTH must be a power of two >= 4"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0] wptr, rptr;
  assign level_o = wptr - rptr;
  assign full_o  = (level_o == DEPTH);
  assign empty_o = (wptr == rptr);
  wire do_wr = wr_en_i & ~full_o;
  wire do_rd = rd_en_i & ~empty_o;
  always_ff @(posedge clk) if (do_wr) mem[wptr[AW-1:0]] <= wdata_i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; rd_valid_o <= 1'b0; rdata_o <= '0;
      overflow_o <= 1'b0; underflow_o <= 1'b0; almost_full_o <= 1'b0; almost_empty_o <= 1'b1;
    end else begin
      if (do_wr) wptr <= wptr + 1'b1;
      rd_valid_o <= do_rd;
      if (do_rd) begin rptr <= rptr + 1'b1; rdata_o <= mem[rptr[AW-1:0]]; end
      if (wr_en_i & full_o)  overflow_o  <= 1'b1;
      if (rd_en_i & empty_o) underflow_o <= 1'b1;
      if (clr_err_i) begin overflow_o <= 1'b0; underflow_o <= 1'b0; end
      almost_full_o  <= ((level_o + do_wr - do_rd) >= afull_thresh_i);
      almost_empty_o <= ((level_o + do_wr - do_rd) <= aempty_thresh_i);
    end
  end
endmodule
