// ***************
// Filename: parity_check.sv
// Author: FPGA Cores 4 U
// Description: Parity checker. Version 1.0.0. err_o goes high for a word
//   whose received parity bit does not match (even parity, or odd with
//   ODD=1); sticky_o remembers any error until clr_i, and err_count_o
//   counts errors (saturating). Words are qualified by valid_i. Clock -
//   clk. Reset - synchronous active low, no errors. Latency - err_o,
//   sticky_o and the counter are registered, 1 clock after valid_i.
//   Detection - all odd numbers of bit flips (including the parity bit);
//   even numbers of flips are not detected. Errors - WIDTH < 1 rejected at
//   elaboration.
// Date: 2026-09-29
module parity_check #(
  parameter int WIDTH   = 8,
  parameter bit ODD     = 1'b0,
  parameter int CNT_W   = 8
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             valid_i,
  input  logic [WIDTH-1:0] data_i,
  input  logic             parity_i,
  input  logic             clr_i,
  output logic             err_o,
  output logic             sticky_o,
  output logic [CNT_W-1:0] err_count_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1 || CNT_W < 1) begin : g_bad $error("parity_check: bad widths"); end
  wire bad = valid_i & ((^{data_i, parity_i}) ^ ODD);
  always_ff @(posedge clk) begin
    if (!rst_n) begin err_o <= 1'b0; sticky_o <= 1'b0; err_count_o <= '0; end
    else begin
      err_o <= bad;
      if (bad) begin sticky_o <= 1'b1; if (err_count_o != '1) err_count_o <= err_count_o + 1'b1; end
      if (clr_i) begin sticky_o <= 1'b0; err_count_o <= '0; end
    end
  end
endmodule
