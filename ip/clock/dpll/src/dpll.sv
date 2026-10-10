// ***************
// Filename: dpll.sv
// Author: FPGA Cores 4 U
// Description: All-digital PLL (ADPLL) with NOUT phase-aligned divided
//   outputs. Version 1.0.0. Oscillator frequency f_vco = REF_KHZ * M / D
//   (fractional ratios allowed), outputs clk_o[n] = f_vco / O[n].
//     dpll_ctrl  phase detector, PI loop filter, lock detector
//                (synthesizable, reference clock domain)
//     dpll_dco   oscillator + phase read-out (TDC) + output dividers and
//                glitch-free output enables (behavioural model; an empty
//                black box under `SYNTHESIS, see dpll_dco.sv)
//   The loop gains and the nominal tuning word are derived here from the
//   frequency parameters: proportional gain alpha = 1/32 .. 1/16 of the
//   phase error corrected per reference cycle, integral gain alpha / 64
//   (damping 0.7 .. 1), so lock takes about 300 reference cycles from a
//   few % oscillator error. Jitter is set by the TDC resolution
//   (1 / 2**TDC_F oscillator cycle).
//   Parameters - REF_KHZ reference frequency; M, D ratio; F_MIN_KHZ /
//   F_MAX_KHZ oscillator tuning range (the target must lie inside);
//   O[16n +: 16] divider of output n; MISMATCH_PPM oscillator error
//   (simulation model only).
//   Clocks - ref_clk in, clk_o out. Reset - rst_n, synchronous to ref_clk,
//   active low (resets the loop; the oscillator keeps running).
//   locked_o (ref_clk domain) is high while the loop is in lock.
//   Simulation speed-up (`define DPLL_IDEAL, not for synthesis): no loop and
//   no oscillator model; every output is a plain toggle, clk = #delay ~clk,
//   with half period T_ref * D * O[n] / (2 M) from the measured reference
//   period (exact ratio, edge times taken from one start so related outputs
//   keep coincident edges); locked_o rises 64 reference cycles after rst_n.
// Date: 2026-10-10
`timescale 1ns/1ps
module dpll #(
  parameter longint REF_KHZ      = 33_333,       // 33.333 MHz board clock
  parameter int     M            = 24,           // 800 MHz oscillator
  parameter int     D            = 1,
  parameter int     NOUT         = 1,
  parameter logic [16*NOUT-1:0] O = {NOUT{16'd4}},  // 200 MHz
  parameter longint F_MIN_KHZ    = 400_000,
  parameter longint F_MAX_KHZ    = 1_600_000,
  parameter int     MISMATCH_PPM = 0
) (
  input  logic            ref_clk,
  input  logic            rst_n,
  input  logic [NOUT-1:0] en_i,
  output logic [NOUT-1:0] clk_o,
  output logic            locked_o
);
  localparam int CW = 24, PW = 32, TDC_F = 8, G = 24;
  localparam longint SPAN     = F_MAX_KHZ - F_MIN_KHZ;
  localparam longint VCO_KHZ  = REF_KHZ * M / D;
  // nominal tuning word for the target frequency
  localparam longint CODE_INIT = ((REF_KHZ * M - F_MIN_KHZ * D) << CW) / (SPAN * D);
  // proportional gain for alpha = 1: X = 2**G * 2**CW * REF / (SPAN * D * 2**TDC_F)
  localparam longint X      = (REF_KHZ << (CW - TDC_F + G)) / (SPAN * D);
  localparam int     KP_SH  = $clog2(X) - 5 - G;      // alpha in [1/32, 1/16)
  localparam int     KI_SH  = KP_SH - 6;              // beta = alpha / 64
  localparam int     LOCK_TOL = (D << TDC_F) / 16;    // 1/16 oscillator cycle

  if (VCO_KHZ < F_MIN_KHZ || VCO_KHZ > F_MAX_KHZ) begin : g_bad_vco
    $error(
    "dpll: oscillator target %0d kHz outside %0d .. %0d kHz",
    VCO_KHZ,
    F_MIN_KHZ,
    F_MAX_KHZ
  );
  end

`ifdef DPLL_IDEAL
`ifndef SYNTHESIS
  // ---------------- ideal clocks (simulation speed-up) ----------------
  realtime t_ref = 0.0, t_start = 0.0;              // measured reference period, common start
  bit started = 1'b0;
  initial begin
    clk_o = '0;
    @(posedge ref_clk) t_ref = $realtime;
    @(posedge ref_clk) t_ref = $realtime - t_ref;
    t_start = $realtime;
    started = 1'b1;
  end
  for (genvar n = 0; n < NOUT; n++) begin : g_ideal
    initial begin : toggle
      realtime half;
      longint k;
      wait (started);
      half = t_ref * D * O[16*n +: 16] / (2.0 * M);
      k = 0;
      clk_o[n] = en_i[n];                            // rising edges on whole periods from the start:
                                                     // related outputs rise together
      // clk = #delay ~clk, the delay to the next edge of this output from the common start (no
      // rounding drift); a rising edge is skipped while en_i[n] is low (glitch-free gate)
      forever begin
        k++;
        clk_o[n] = #(t_start + k * half - $realtime) (clk_o[n] ? 1'b0 : en_i[n]);
      end
    end
  end
  logic [6:0] lock_cnt;
  always_ff @(posedge ref_clk) begin
    if (!rst_n || !started) begin
      lock_cnt <= '0;
      locked_o <= 1'b0;
    end else if (lock_cnt != 7'd64) lock_cnt <= lock_cnt + 1'b1;
    else locked_o <= 1'b1;
  end
`endif
`else
  logic [CW-1:0] code;
  logic [PW-1:0] phase;
  dpll_ctrl #(
    .M(M),
    .D(D),
    .CW(CW),
    .PW(PW),
    .TDC_F(TDC_F),
    .G(G),
    .KP_SH(KP_SH),
    .KI_SH(KI_SH),
    .CODE_INIT(CODE_INIT),
    .LOCK_TOL(LOCK_TOL > 0 ? LOCK_TOL : 1),
    .LOCK_CNT(64)
  ) u_ctrl (
    .clk(ref_clk),
    .rst_n,
    .phase_i(phase),
    .code_o(code),
    .locked_o
  );
  dpll_dco #(
    .NOUT(NOUT),
    .CW(CW),
    .PW(PW),
    .TDC_F(TDC_F),
    .F_MIN_KHZ(F_MIN_KHZ),
    .F_MAX_KHZ(F_MAX_KHZ),
    .O(O),
    .MISMATCH_PPM(MISMATCH_PPM)
  ) u_dco (
    .ref_clk,
    .code_i(code),
    .en_i,
    .phase_o(phase),
    .clk_o
  );
`endif
endmodule
