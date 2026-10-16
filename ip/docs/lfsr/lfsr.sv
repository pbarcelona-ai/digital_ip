// ***************
// Filename: lfsr.sv
// Author: FPGA Cores 4 U
// Description: Linear-feedback shift register / PRBS generator. Version
//   1.0.0. Fibonacci LFSR of WIDTH bits with feedback taps TAPS (bit i of
//   TAPS set means state bit i is XORed into the feedback). Defaults
//   implement PRBS7 (x^7+x^6+1, TAPS=0x60, period 127). STEPS shifts are
//   computed per enabled clock (parallel PRBS, STEPS bits per clock,
//   bit_o[STEPS-1:0] with bit 0 the oldest). load_i loads seed_i; an all-
//   zero seed (the lock-up state) is replaced by SEED and flagged on
//   lockup_o. Clock - clk. Reset - synchronous active low, state = SEED.
//   Latency - state_o updates 1 clock after en_i. Errors - WIDTH < 2,
//   STEPS < 1, TAPS = 0 or SEED = 0 rejected at elaboration.
// Date: 2026-09-29

module lfsr #(
  parameter int WIDTH = 7,
  parameter logic [WIDTH-1:0] TAPS = 7'h60,
  parameter logic [WIDTH-1:0] SEED = 7'h7F,
  parameter int STEPS = 1
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             load_i,
  input  logic [WIDTH-1:0] seed_i,
  output logic [WIDTH-1:0] state_o,
  output logic [STEPS-1:0] bit_o,
  output logic             lockup_o
);
