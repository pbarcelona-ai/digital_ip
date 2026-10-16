// ***************
// Filename: cic.sv
// Author: FPGA Cores 4 U
// Description: CIC decimation filter (cascaded integrator-comb). Version
//   1.0.0. N integrators run at the input rate with wrap-around
//   arithmetic, the stream is decimated by r_i (1..RMAX, run-time
//   programmable, latched at the start of each output period) and N combs
//   (differential delay 1) run at the output rate. Register width is
//   DATA_W + N*ceil(log2(RMAX)) so the wrap-around cannot corrupt the
//   result. DC gain is r^N; the output is the arithmetic right shift of
//   the comb result by shift_i (use N*log2(r) for power-of-two ratios to
//   get unity gain), rounded and saturated to OUT_W bits (sat_o flags
//   clipping). Clock - clk, one input per valid_i. Reset - synchronous
//   active low clears all integrators and combs. Latency - the output
//   appears with the clock after the r_i-th input of a period (1 clock).
//   Droop - CIC passband droop is not compensated (follow with a fir).
//   Errors - N or RMAX out of range rejected at elaboration; r_i outside
//   1..RMAX is clamped and flagged on r_err_o.
// Date: 2026-09-29

module cic #(
  parameter int N       = 3,
  parameter int RMAX    = 64,
  parameter int DATA_W  = 16,
  parameter int OUT_W   = 16
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic [$clog2(RMAX+1)-1:0]   r_i,
  input  logic [7:0]                  shift_i,
  input  logic                        valid_i,
  input  logic signed [DATA_W-1:0]    data_i,
  output logic                        valid_o,
  output logic signed [OUT_W-1:0]     data_o,
  output logic                        sat_o,
  output logic                        r_err_o
);
