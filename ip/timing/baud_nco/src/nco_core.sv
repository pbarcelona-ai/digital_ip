// ***************
// Filename: nco_core.sv
// Author: FPGA Cores 4 U
// Description: Pipelined numerically controlled oscillator. A PHASE_W bit
//   phase accumulator produces a carry tick (baud / sample strobe) and a
//   square wave. The phase is offset, folded into a quarter wave ROM lookup
//   for sine and cosine, sign corrected and scaled by a Q0.15 gain in DSP48
//   multipliers. All stages stall together on the adv input so an AXI-Stream
//   consumer can apply back pressure. Output latency is fixed (see LAT).
//   Version 1.0.0. Helper block of its IP; see the top level description for
//   clock, reset, latency and error behavior. Clock - the clock of the parent
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module nco_core #(
  parameter int PHASE_W = 32              // 16..32 accumulator bits
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               en,          // oscillator enabled
  input  logic               adv,         // pipeline advance (stall control)
  input  logic               phase_rst,   // synchronous phase clear pulse
  input  logic [PHASE_W-1:0] fcw,         // frequency control word
  input  logic [15:0]        phase_off,   // phase offset, 1/65536 cycle
  input  logic [14:0]        gain,        // amplitude, Q0.15
  output logic               tick_o,      // accumulator carry strobe
  output logic               sq_o,        // square wave (phase MSB)
  output logic               valid_o,     // sample outputs valid
  output logic signed [15:0] sin_o,
  output logic signed [15:0] cos_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (PHASE_W < 16 || PHASE_W > 32) begin : g_chk_pw $error("%m: PHASE_W must be 16..32"); end

  localparam int LAT = 5;                 // stages after the accumulator

  // ---- Stage 0: phase accumulator with carry output ----
  logic [PHASE_W-1:0] acc;
  wire  [PHASE_W:0]   acc_sum = {1'b0, acc} + {1'b0, fcw};

  // ---- Valid pipeline ----
  logic [LAT-1:0] vld;

  // ---- Stage 1: add phase offset ----
  logic [PHASE_W-1:0] ph1;
  wire  [PHASE_W-1:0] off_ext = {phase_off, {(PHASE_W-16){1'b0}}};

  // ---- Stage 2: fold phase into ROM address and sign ----
  logic [7:0] addr_s, addr_c;
  logic       neg_s2, neg_c2;
  wire  [9:0] p10   = ph1[PHASE_W-1 -: 10];           // 10 bit phase
  wire  [9:0] p10_c = p10 + 10'd256;                  // cosine = +90 deg

  // ---- Stage 3: ROM output (registered inside the ROM) ----
  logic [14:0] mag_s, mag_c;
  logic        neg_s3, neg_c3;

  // ---- Stage 4: apply sign, register multiplier inputs ----
  logic signed [15:0] sval, cval;
  logic signed [15:0] gain_q;

  // ---- Stage 5: DSP multiply (input regs -> product reg) ----
  logic signed [31:0] prod_s, prod_c;

  nco_sine_rom u_rom (
    .clk(clk),
    .en(adv),
    .addr_a(addr_s),
    .addr_b(addr_c),
    .dout_a(mag_s),
    .dout_b(mag_c)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc    <= '0;
      vld    <= '0;
      tick_o <= 1'b0;
      ph1    <= '0;
    end else if (phase_rst) begin
      acc    <= '0;                            // restart phase and pipeline
      vld    <= '0;
      tick_o <= 1'b0;
    end else if (adv) begin
      tick_o <= en & acc_sum[PHASE_W];         // baud tick on carry
      if (en) acc <= acc_sum[PHASE_W-1:0];
      vld    <= {vld[LAT-2:0], en};
      ph1    <= acc + off_ext;
    end else begin
      tick_o <= 1'b0;                          // no tick while stalled
    end
  end

  // Datapath registers (no reset needed, gated by the valid pipeline)
  always_ff @(posedge clk) begin
    if (adv) begin
      // Stage 2: mirror index on odd quadrants, sign on quadrants 2,3
      addr_s <= p10[8]   ? ~p10[7:0]   : p10[7:0];
      addr_c <= p10_c[8] ? ~p10_c[7:0] : p10_c[7:0];
      neg_s2 <= p10[9];
      neg_c2 <= p10_c[9];
      neg_s3 <= neg_s2;                        // align with ROM latency
      neg_c3 <= neg_c2;
      // Stage 4: sign application
      sval   <= neg_s3 ? -$signed({1'b0, mag_s}) : $signed({1'b0, mag_s});
      cval   <= neg_c3 ? -$signed({1'b0, mag_c}) : $signed({1'b0, mag_c});
      gain_q <= $signed({1'b0, gain});
      // Stage 5: multiply, pattern maps to DSP48E1 with A/B/P registers
      prod_s <= sval * gain_q;
      prod_c <= cval * gain_q;
    end
  end

  assign sq_o    = acc[PHASE_W-1];
  assign valid_o = vld[LAT-1];
  assign sin_o   = prod_s[30:15];
  assign cos_o   = prod_c[30:15];
endmodule
