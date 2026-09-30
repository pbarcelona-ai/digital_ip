// ***************
// Filename: parity_gen.sv
// Author: Paul Barcelona
// Description: Parity generator. Version 1.0.0. parity_o is the XOR reduction
//   of data_i (even parity - data plus parity bit contain an even number of
//   ones) or its inverse for ODD=1. REGISTERED=1 adds one output register
//   (latency 1, synchronous active-low reset to the parity of an all-zero
//   word); otherwise the module is combinational with 0 latency and clk/rst_n
//   unused. Clock - clk when registered. Timing - log2(WIDTH) XOR levels;
//   register wide words at 100 MHz. Errors - WIDTH < 1 rejected at
//   elaboration. Reset - synchronous, driven by the parent block. Latency -
//   as documented in the parent block, fixed and independent of data.
//   as documented in the parent block, fixed and independent of data.
// Date: 2026-09-29
module parity_gen #(
  parameter int WIDTH      = 8,
  parameter bit ODD        = 1'b0,
  parameter bit REGISTERED = 1'b0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] data_i,
  output logic             parity_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1) begin : g_bad $error("parity_gen: WIDTH must be >= 1"); end
  wire p = (^data_i) ^ ODD;
  if (REGISTERED) begin : g_reg
    always_ff @(posedge clk) begin if (!rst_n) parity_o <= ODD; else parity_o <= p; end
  end else begin : g_comb
    assign parity_o = p;
  end
endmodule
