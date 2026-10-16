// ***************
// Filename: frequency_counter.sv
// Author: FPGA Cores 4 U
// Description: Input frequency counter. Version 1.0.0. Counts rising edges
//   of the (asynchronous) signal sig_i during a gate window of gate_clks_i
//   system clocks and reports the edge count in count_o with a one-clock
//   valid_o pulse after every window; frequency = count * f_clk /
//   gate_clks. The input passes a 2-flop synchronizer, so signals up to
//   f_clk/4 are counted correctly (higher rates alias); over_o flags a
//   count that saturated. Clock - clk. Reset - synchronous active low.
//   Latency - one gate window plus 4 clocks. Resolution - +/-1 count per
//   window; a longer gate improves resolution. Errors - gate_clks_i = 0
//   disables measuring; saturation flagged on over_o (sticky per result).
// Date: 2026-09-29

module frequency_counter #(
  parameter int COUNT_W = 32,
  parameter int GATE_W  = 32
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               en_i,
  input  logic [GATE_W-1:0]  gate_clks_i,
  input  logic               sig_i,
  output logic [COUNT_W-1:0] count_o,
  output logic               valid_o,
  output logic               over_o
);
