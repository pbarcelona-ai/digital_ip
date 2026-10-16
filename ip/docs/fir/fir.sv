// ***************
// Filename: fir.sv
// Author: FPGA Cores 4 U
// Description: Streaming FIR filter (transposed form, run-time loadable
//   coefficients). Version 1.0.0. TAPS coefficients of COEF_W bits
//   (signed, load with coef_we_i / coef_idx_i / coef_i at any time; a
//   coefficient change applies from the next sample) process one input
//   sample per valid_i with a fully parallel multiplier array (maps to DSP
//   blocks). The accumulator is DATA_W+COEF_W+log2(TAPS) bits wide so it
//   never overflows; the output is rounded (add half LSB), shifted right
//   by OUT_SHIFT and saturated to OUT_W bits (sat_o pulses when clipping).
//   A coefficient set with sum equal to 2^OUT_SHIFT has unity DC gain.
//   Clock - clk. Reset - synchronous active low clears the delay line, all
//   coefficients and valid_o. Latency - 1 clock from valid_i to valid_o.
//   Throughput - one sample per clock, no back-pressure (valid_i may be
//   gated freely; the filter only advances on valid_i). Errors - TAPS < 2,
//   widths < 2 or OUT_SHIFT beyond the accumulator rejected at
//   elaboration.
// Date: 2026-09-29

module fir #(
  parameter int TAPS      = 8,
  parameter int DATA_W    = 16,
  parameter int COEF_W    = 16,
  parameter int OUT_W     = 16,
  parameter int OUT_SHIFT = 15
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // coefficient load
  input  logic                     coef_we_i,
  input  logic [$clog2(TAPS)-1:0]  coef_idx_i,
  input  logic signed [COEF_W-1:0] coef_i,
  // sample stream
  input  logic                     valid_i,
  input  logic signed [DATA_W-1:0] data_i,
  output logic                     valid_o,
  output logic signed [OUT_W-1:0]  data_o,
  output logic                     sat_o
);
