// ***************
// Filename: async_fifo.sv
// Author: FPGA Cores 4 U
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
