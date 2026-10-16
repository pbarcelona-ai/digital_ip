// ***************
// Filename: onehot_decoder.sv
// Author: FPGA Cores 4 U
// Description: Binary to one-hot decoder with enable. Version 1.0.0. Bit
//   sel_i of onehot_o is set when en_i is high. A select value >= WIDTH sets
//   err_o and produces an all-zero output. REGISTERED=1 adds one output
//   register stage (latency 1, synchronous reset to zero); otherwise the
//   block is combinational (latency 0). Errors - out-of- range select flagged
//   on err_o; WIDTH < 2 rejected at elaboration. Clock - the clock of the
//   parent block, all signals are synchronous to it. Reset - synchronous,
//   driven by the parent block. Latency - as documented in the parent block,
//   fixed and independent of data.
//   parent block, all signals are synchronous to it. Reset - synchronous,
//   driven by the parent block. Latency - as documented in the parent block,
//   fixed and independent of data.
// Date: 2026-09-29

module onehot_decoder #(
  parameter int WIDTH      = 8,
  parameter bit REGISTERED = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en_i,
  input  logic [$clog2(WIDTH)-1:0] sel_i,
  output logic [WIDTH-1:0]         onehot_o,
  output logic                     err_o
);
