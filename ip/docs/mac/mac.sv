// ***************
// Filename: mac.sv
// Author: FPGA Cores 4 U
// Description: One-cycle-latency multiply-accumulate unit. Fixed-point mode
//   supports independent operand widths/signs and Q-format binary points,
//   optional round-to-nearest-even, output saturation, and overflow/inexact
//   flags. Floating-point mode is IEEE-754 binary32 fused multiply-add with
//   round-to-nearest-even and overflow/underflow/inexact/invalid flags.
//   Clock - clk. Reset - synchronous active-low rst_n. Latency - one clock
//   from valid_i to valid_o. Throughput - one result per clock. Errors - bad
//   widths/fraction positions or non-binary32 floating-point widths rejected
//   at elaboration.
// Date: 2026-09-30

module mac #(
  parameter int A_WIDTH = 16,
  parameter int B_WIDTH = 16,
  parameter int ACC_WIDTH = 40,
  parameter int OUT_WIDTH = ACC_WIDTH,
  parameter bit A_SIGNED = 1'b1,
  parameter bit B_SIGNED = 1'b1,
  parameter bit ACC_SIGNED = 1'b1,
  parameter bit OUT_SIGNED = ACC_SIGNED,
  parameter int A_FRAC_BITS = 0,
  parameter int B_FRAC_BITS = 0,
  parameter int ACC_FRAC_BITS = 0,
  parameter bit FLOATING_POINT = 1'b0,
  parameter bit ROUND_FIXED = 1'b1,
  parameter bit SATURATE = 1'b1
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  valid_i,
  input  logic [A_WIDTH-1:0]    a_i,
  input  logic [B_WIDTH-1:0]    b_i,
  input  logic [ACC_WIDTH-1:0]  acc_i,
  output logic                  valid_o,
  output logic [OUT_WIDTH-1:0]  result_o,
  output logic                  overflow_o,
  output logic                  underflow_o,
  output logic                  inexact_o,
  output logic                  invalid_o
);
