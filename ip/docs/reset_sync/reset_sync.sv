// ***************
// Filename: reset_sync.sv
// Author: FPGA Cores 4 U
// Description: Reset synchronizer. Version 1.0.0. Brings an asynchronous
//   reset into the clk domain. ASYNC_ASSERT=1 (default) asserts the output
//   immediately and releases it synchronously after STAGES clocks;
//   ASYNC_ASSERT=0 samples the input with the clock so both edges are
//   synchronous. Polarity of the input and output is selectable. Clock -
//   clk; arst_i may be asynchronous. Reset state - output asserted.
//   Latency - release takes STAGES clocks (assert is immediate for async
//   type). Timing - the flops are marked async_reg. Errors - STAGES<2
//   rejected at elaboration.
// Date: 2026-09-29

module reset_sync #(
  parameter int STAGES       = 2,
  parameter bit ACTIVE_LOW_IN  = 1'b1,   // polarity of arst_i
  parameter bit ACTIVE_LOW_OUT = 1'b1,   // polarity of rst_o
  parameter bit ASYNC_ASSERT   = 1'b1    // 1: async assert, sync release
) (
  input  logic clk,
  input  logic arst_i,
  output logic rst_o
);
