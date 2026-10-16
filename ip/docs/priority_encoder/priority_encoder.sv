// ***************
// Filename: priority_encoder.sv
// Author: FPGA Cores 4 U
// Description: Priority encoder. Version 1.0.0. Encodes the highest- priority
//   asserted request: LSB_HIGH=1 gives bit 0 the highest priority, LSB_HIGH=0
//   gives the MSB. Outputs the index, a one-hot vector and a valid flag.
//   REGISTERED=1 adds one output register stage (latency 1, synchronous reset
//   to invalid); otherwise the module is purely combinational (latency 0) and
//   clk/rst_n are unused. Timing - log2(WIDTH) LUT levels; register the
//   output for wide vectors at 100 MHz. Errors - WIDTH < 2 rejected at
//   elaboration; idx_o is 0 when valid_o is low. Clock - the clock of the
//   parent block, all signals are synchronous to it. Reset - synchronous,
//   driven by the parent block. Latency - as documented in the parent block,
//   fixed and independent of data.
//   driven by the parent block. Latency - as documented in the parent block,
//   fixed and independent of data.
// Date: 2026-09-29

module priority_encoder #(
  parameter int WIDTH      = 8,
  parameter bit LSB_HIGH   = 1'b1,
  parameter bit REGISTERED = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [WIDTH-1:0]         req_i,
  output logic [$clog2(WIDTH)-1:0] idx_o,
  output logic [WIDTH-1:0]         onehot_o,
  output logic                     valid_o
);
