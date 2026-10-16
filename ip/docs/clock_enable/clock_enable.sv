// ***************
// Filename: clock_enable.sv
// Author: FPGA Cores 4 U
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
