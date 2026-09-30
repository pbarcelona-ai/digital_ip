// ***************
// Filename: dds.sv
// Author: Paul Barcelona
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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (ZW > PHASE_W) begin : g_bz $error("dds: ZW must not exceed PHASE_W"); end
  logic [PHASE_W-1:0] ph; logic en_d, nco_carry, nco_msb;
  nco #(.PHASE_W(PHASE_W)) u_nco (.clk, .rst_n, .ce_i(en_i), .tuning_i, .phase_off_i, .sync_load_i, .phase_load_i,
                                  .phase_o(ph), .carry_o(nco_carry), .msb_o(nco_msb), .nyquist_o);
  always_ff @(posedge clk) begin
    if (!rst_n) en_d <= 1'b0; else en_d <= en_i | sync_load_i;
  end
  localparam logic signed [OUT_W-1:0] AMP = {1'b0, {(OUT_W-1){1'b1}}};
  cordic #(.WIDTH(OUT_W), .ZW(ZW), .ITER(ITER), .MODE(0)) u_cordic (
    .clk, .rst_n, .valid_i(en_d), .x_i(AMP), .y_i('0), .z_i(ph[PHASE_W-1 -: ZW]),
    .valid_o, .x_o(cos_o), .y_o(sin_o), .mag_o(), .z_o());
endmodule
