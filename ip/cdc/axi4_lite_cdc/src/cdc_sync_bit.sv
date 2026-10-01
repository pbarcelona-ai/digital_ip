// ***************
// Filename: cdc_sync_bit.sv
// Author: FPGA Cores 4 U
// Description: Multi-stage flop synchronizer for a single bit crossing into
//   the destination clock domain. Marked async_reg so tools place the flops
//   together. Output is the synchronized level. Version 1.0.0. Helper block
//   of its IP; see the top level description for clock, reset, latency and
//   error behavior. Clock - the clock of the parent block, all signals are
//   synchronous to it. Reset - none, the registers are cleared by the parent
//   block's control flow. Latency - as documented in the parent block, fixed
//   and independent of data. Errors - none reported here, out-of-range
//   parameters stop elaboration or are handled by the parent block.
//   synchronous to it. Reset - none, the registers are cleared by the parent
//   block's control flow. Latency - as documented in the parent block, fixed
//   and independent of data. Errors - none reported here, out-of-range
//   parameters stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module cdc_sync_bit #(
  parameter int STAGES = 2
) (
  input  logic clk,        // destination clock
  input  logic d_i,        // asynchronous input
  output logic q_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_chk_stg $error("%m: STAGES must be >= 2"); end

  (* async_reg = "true", shreg_extract = "no" *) logic [STAGES-1:0] sr = '0;
  always_ff @(posedge clk) sr <= {sr[STAGES-2:0], d_i};
  assign q_o = sr[STAGES-1];
endmodule
