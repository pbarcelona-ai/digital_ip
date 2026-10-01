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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int ACC_W = DATA_W + COEF_W + $clog2(TAPS);
  if (TAPS < 2 || DATA_W < 2 || COEF_W < 2 || OUT_W < 2) begin : g_bad $error("fir: bad TAPS/widths"); end
  if (OUT_SHIFT < 0 || OUT_SHIFT >= ACC_W) begin : g_bs $error("fir: OUT_SHIFT out of range"); end
  logic signed [COEF_W-1:0] coef [0:TAPS-1];
  logic signed [ACC_W-1:0]  z    [0:TAPS-2];
  logic signed [ACC_W-1:0]  prod [0:TAPS-1];
  logic signed [ACC_W-1:0]  y_full, y_rnd, y_sh;
  always_comb begin
    for (int k = 0; k < TAPS; k++) prod[k] = data_i * coef[k];
    y_full = prod[0] + z[0];
    y_rnd  = (OUT_SHIFT > 0) ? (y_full + (ACC_W'(1) <<< (OUT_SHIFT - 1))) : y_full;
    y_sh   = y_rnd >>> OUT_SHIFT;
  end
  localparam logic signed [ACC_W-1:0] MAXV = (ACC_W'(1) <<< (OUT_W - 1)) - 1;
  localparam logic signed [ACC_W-1:0] MINV = -(ACC_W'(1) <<< (OUT_W - 1));
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int k = 0; k < TAPS; k++) coef[k] <= '0;
      for (int k = 0; k < TAPS-1; k++) z[k] <= '0;
      valid_o <= 1'b0; data_o <= '0; sat_o <= 1'b0;
    end else begin
      if (coef_we_i) coef[coef_idx_i] <= coef_i;
      valid_o <= valid_i; sat_o <= 1'b0;
      if (valid_i) begin
        for (int k = 0; k < TAPS-2; k++) z[k] <= prod[k+1] + z[k+1];
        z[TAPS-2] <= prod[TAPS-1];
        if (y_sh > MAXV) begin data_o <= MAXV[OUT_W-1:0]; sat_o <= 1'b1; end
        else if (y_sh < MINV) begin data_o <= MINV[OUT_W-1:0]; sat_o <= 1'b1; end
        else data_o <= y_sh[OUT_W-1:0];
      end
    end
  end
endmodule
