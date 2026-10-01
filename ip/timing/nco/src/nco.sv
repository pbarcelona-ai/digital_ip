// ***************
// Filename: nco.sv
// Author: FPGA Cores 4 U
// Description: Numerically controlled oscillator (phase accumulator).
//   Version 1.0.0. phase_o advances by tuning_i each ce_i clock, so f_out
//   = tuning_i * f_clk / 2^PHASE_W. Optional phase offset (phase_off_i) is
//   added to the output phase only. carry_o pulses each time the
//   accumulator overflows (a square-wave/tick source with frequency f_out)
//   and msb_o is the accumulator MSB (50 percent duty square wave). Clock
//   - clk with clock enable ce_i. Reset - synchronous active low, phase =
//   0. sync_load_i loads phase_load_i. Latency - phase_o and carry_o are
//   registered, 1 clock after ce_i. Timing - one PHASE_W bit adder per
//   clock; for PHASE_W > 32 add pipeline stages in the caller. Errors -
//   PHASE_W < 2 rejected at elaboration; tuning_i >= 2^(PHASE_W-1) exceeds
//   Nyquist and is flagged on nyquist_o.
// Date: 2026-09-29
module nco #(
  parameter int PHASE_W = 32
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               ce_i,
  input  logic [PHASE_W-1:0] tuning_i,
  input  logic [PHASE_W-1:0] phase_off_i,
  input  logic               sync_load_i,
  input  logic [PHASE_W-1:0] phase_load_i,
  output logic [PHASE_W-1:0] phase_o,      // accumulator + offset
  output logic               carry_o,      // accumulator overflow pulse
  output logic               msb_o,        // accumulator MSB
  output logic               nyquist_o     // tuning word above Nyquist
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (PHASE_W < 2) begin : g_bad $error("nco: PHASE_W must be >= 2"); end
  logic [PHASE_W-1:0] acc;
  logic [PHASE_W:0]   sum;
  assign sum       = {1'b0, acc} + {1'b0, tuning_i};
  assign nyquist_o = tuning_i[PHASE_W-1];
  always_ff @(posedge clk) begin
    if (!rst_n) begin acc <= '0; carry_o <= 1'b0; phase_o <= '0; end
    else if (sync_load_i) begin acc <= phase_load_i; carry_o <= 1'b0; phase_o <= phase_load_i + phase_off_i; end
    else if (ce_i) begin
      acc <= sum[PHASE_W-1:0]; carry_o <= sum[PHASE_W];
      phase_o <= sum[PHASE_W-1:0] + phase_off_i;
    end else carry_o <= 1'b0;
  end
  assign msb_o = acc[PHASE_W-1];
endmodule
