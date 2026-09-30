// ***************
// Filename: clock_enable.sv
// Author: Paul Barcelona
// Description: Programmable clock-enable generator. Version 1.0.0.
//   Produces a one-clock ce_o pulse every DIV clocks (DIV = div_i, values
//   0 and 1 give a pulse every clock). The divide ratio may change at any
//   time and takes effect at the next pulse. Clock - clk. Reset -
//   synchronous active low; counter cleared, ce_o low. Latency - ce_o is
//   registered; first pulse DIV clocks after en_i rises. Timing - one
//   counter compare per clock, DIV_W bit wide. Errors - DIV_W < 1 rejected
//   at elaboration. Does not divide the clock itself; use ce_o as an
//   enable on clk.
// Date: 2026-09-29
module clock_enable #(
  parameter int DIV_W = 16
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic [DIV_W-1:0] div_i,        // clocks per pulse
  output logic             ce_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DIV_W < 1) begin : g_bad $error("clock_enable: DIV_W must be >= 1"); end
  logic [DIV_W-1:0] cnt;
  always_ff @(posedge clk) begin
    if (!rst_n || !en_i) begin cnt <= '0; ce_o <= 1'b0; end
    else if (div_i <= 1) begin cnt <= '0; ce_o <= 1'b1; end
    else if (cnt >= div_i - 1'b1) begin cnt <= '0; ce_o <= 1'b1; end
    else begin cnt <= cnt + 1'b1; ce_o <= 1'b0; end
  end
endmodule
