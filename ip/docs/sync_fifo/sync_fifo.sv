// ***************
// Filename: sync_fifo.sv
// Author: FPGA Cores 4 U
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
