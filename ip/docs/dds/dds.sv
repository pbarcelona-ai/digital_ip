// ***************
// Filename: dds.sv
// Author: FPGA Cores 4 U
// Description: Direct digital synthesizer (sine/cosine generator). Version
//   1.0.0. A PHASE_W bit phase accumulator (nco) steps by tuning_i on
//   every enabled clock (f_out = tuning * f_clk / 2^PHASE_W, so 1 MHz at
//   100 MHz needs tuning = 2^32/100) and its top ZW bits drive a cordic in
//   rotation mode that turns the phase into signed sin_o and cos_o of
//   amplitude 2^(OUT_W-1)-1 - no lookup table, so the resolution
//   parameters are freely configurable. phase_off_i adds a phase offset
//   (phase modulation) and sync_load_i loads the accumulator. Clock - clk,
//   one sample per enabled clock. Reset - synchronous active low, phase 0,
//   valid_o low. Latency - ITER+3 clocks from en_i to valid output.
//   Accuracy - about 4 LSB plus the phase truncation error of 2^-ZW turns;
//   spurious-free range grows with ZW. Tuning above half the sample rate
//   aliases (nyquist_o flags it). Errors - parameter ranges are checked by
//   the nco and cordic instances at elaboration.
// Date: 2026-09-29

module dds #(
  parameter int PHASE_W = 32,
  parameter int OUT_W   = 16,
  parameter int ZW      = 16,
  parameter int ITER    = 16
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en_i,
  input  logic [PHASE_W-1:0]       tuning_i,
  input  logic [PHASE_W-1:0]       phase_off_i,
  input  logic                     sync_load_i,
  input  logic [PHASE_W-1:0]       phase_load_i,
  output logic                     valid_o,
  output logic signed [OUT_W-1:0]  sin_o,
  output logic signed [OUT_W-1:0]  cos_o,
  output logic                     nyquist_o
);
