// ***************
// Filename: dpll_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Digital loop of dpll: phase detector, PI loop filter and lock
//   detector. Version 1.0.0. Synthesizable; runs on the reference clock.
//   Phase detector - the oscillator phase phase_i (cycles, TDC_F fractional
//   bits, modulo 2**PW) is compared with the ideal phase, which advances by
//   M / D oscillator cycles per reference cycle. In units of 1 / (D *
//   2**TDC_F) cycles: err = D * phase_i - acc, acc += M * 2**TDC_F, both
//   modulo 2**PW (no divider, so fractional M / D is exact). The first
//   sample after reset sets acc (zero initial phase error).
//   Loop filter - type II PI: integ -= err * 2**KI_SH, code_o = integ -
//   err * 2**KP_SH (err > 0: oscillator ahead), in tuning-word LSBs with G fractional bits (shifts are
//   applied to the G-scaled value, so KP_SH / KI_SH may be negative down
//   to -G), clamped to [0, 2**CW - 1]. integ starts at CODE_INIT (the
//   nominal tuning word), so the loop only corrects the oscillator error.
//   Lock - locked_o rises after LOCK_CNT consecutive updates with |err| <=
//   LOCK_TOL and falls when |err| > 4 * LOCK_TOL.
//   Clock - clk (reference). Reset - rst_n, synchronous, active low.
//   Latency - one reference clock from phase_i to code_o.
// Date: 2026-10-09
module dpll_ctrl #(
  parameter int     M         = 1,           // feedback multiplier
  parameter int     D         = 1,           // reference divider
  parameter int     CW        = 24,          // tuning word width
  parameter int     PW        = 32,          // phase width
  parameter int     TDC_F     = 8,           // fractional phase bits
  parameter int     G         = 24,          // fractional bits of the loop filter
  parameter int     KP_SH     = 0,           // proportional gain 2**KP_SH (tuning LSB per err LSB)
  parameter int     KI_SH     = -6,          // integral gain 2**KI_SH
  parameter longint CODE_INIT = 0,           // nominal tuning word
  parameter int     LOCK_TOL  = 32,          // |err| bound for lock, err LSBs
  parameter int     LOCK_CNT  = 64           // updates within LOCK_TOL to declare lock
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [PW-1:0] phase_i,
  output logic [CW-1:0] code_o,
  output logic          locked_o
);
  localparam int AW = 64;                            // filter arithmetic width
  localparam logic [PW-1:0] STEP = PW'(longint'(M) << TDC_F);
  localparam logic signed [AW-1:0] CMAX = (AW'(1) << (CW + G)) - 1;
  if (KP_SH + G < 0 || KI_SH + G < 0) begin : g_bad_gain
    $error("dpll_ctrl: KP_SH and KI_SH must be >= -G");
  end
  if (M < 1 || D < 1) begin : g_bad_ratio
    $error("dpll_ctrl: M and D must be >= 1");
  end

  logic [PW-1:0] acc;
  logic started;
  logic signed [PW-1:0] err;
  assign err = $signed(PW'(D * phase_i) - acc);

  logic signed [AW-1:0] err_x, integ, integ_n, sum;
  assign err_x   = AW'(err);
  assign integ_n = integ - (err_x <<< (KI_SH + G));    // err > 0: oscillator ahead, slow down
  assign sum     = integ_n - (err_x <<< (KP_SH + G));

  logic [AW-1:0] mag;
  assign mag = err_x < 0 ? AW'(-err_x) : AW'(err_x);
  logic [$clog2(LOCK_CNT+1)-1:0] lcnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc      <= '0;
      started  <= 1'b0;
      integ    <= AW'(CODE_INIT) <<< G;
      code_o   <= CW'(CODE_INIT);
      lcnt     <= '0;
      locked_o <= 1'b0;
    end else if (!started) begin
      acc     <= PW'(D * phase_i) + STEP;            // zero phase error from here on
      started <= 1'b1;
    end else begin
      acc <= acc + STEP;
      // PI filter, integrator clamped to the tuning range (anti wind-up)
      integ <= integ_n < 0 ? '0 : integ_n > CMAX ? CMAX : integ_n;
      code_o <= sum < 0 ? '0 : sum > CMAX ? {CW{1'b1}} : CW'(sum >>> G);
      // lock detector
      if (mag > AW'(LOCK_TOL)) lcnt <= '0;
      else if (lcnt != LOCK_CNT) lcnt <= lcnt + 1'b1;
      if (lcnt == LOCK_CNT) locked_o <= 1'b1;
      else if (mag > AW'(4 * LOCK_TOL)) locked_o <= 1'b0;
    end
  end
endmodule
