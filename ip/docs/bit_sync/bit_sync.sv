// ***************
// Filename: bit_sync.sv
// Author: FPGA Cores 4 U
// Description: Multi-flop synchronizer for a single-bit asynchronous
//   signal entering the clk domain. Version 1.0.0. Clock domain - all
//   state runs on clk, d_i may be fully asynchronous but must be glitch
//   free and held for at least one clk period (use pulse_sync for pulses).
//   Reset - synchronous, active low; flops load RESET_VAL. Latency -
//   STAGES clock cycles. Timing - the flops carry async_reg so tools keep
//   them together; no logic between stages. Errors - STAGES < 2 is
//   rejected at elaboration.
// Date: 2026-09-29

module bit_sync #(
  parameter int STAGES    = 2,           // synchronizer depth (>= 2)
  parameter bit RESET_VAL = 1'b0         // value held during reset
) (
  input  logic clk,
  input  logic rst_n,
  input  logic d_i,                      // asynchronous input
  output logic q_o                       // synchronized output
);
