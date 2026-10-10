// ***************
// Filename: dpll_dco.sv
// Author: FPGA Cores 4 U
// Description: Digitally controlled oscillator with phase read-out (TDC)
//   and NOUT divided outputs, the analogue part of dpll. Version 1.0.0.
//   Behavioural simulation model: a ring / LC DCO and its time-to-digital
//   converter are device specific, so for synthesis this module is an
//   empty black box (`SYNTHESIS) to be replaced by the device PLL / MMCM or
//   a hard DCO + TDC macro.
//   Oscillator - frequency f = (F_MIN_KHZ + code_i * (F_MAX_KHZ -
//   F_MIN_KHZ) / 2**CW) * (1 + MISMATCH_PPM / 1e6); the mismatch models a
//   process / temperature offset that the loop has to correct. The
//   oscillator itself is never toggled: its phase is a real number, and
//   only the output edges are scheduled, so a multi-GHz VCO costs nothing
//   in simulation time. A new code_i takes effect at the next output edge
//   (or at once while every output is stopped), phase continuous.
//   Outputs - clk_o[n] = f / O[n] (O[n] >= 1, 16 bits each in O), 50 %
//   duty also for odd O[n] (edges on oscillator half periods). All outputs
//   are phase aligned: output n rises on oscillator half periods 2 k O[n],
//   so an output rises together with every output whose divider divides
//   its own (e.g. a 10:1 serial clock and its pixel clock).
//   en_i[n] gates clk_o[n] glitch free (like a BUFGCE): a rising edge is
//   suppressed while en_i[n] is low, a high phase always completes.
//   Phase read-out - phase_o = oscillator phase in cycles with TDC_F
//   fractional bits, modulo 2**PW, registered on every rising ref_clk
//   edge (integer part = cycle counter, fraction = TDC).
//   Clocks - ref_clk samples the phase; clk_o are generated. Reset - none
//   (the oscillator runs from time 0). Latency - phase_o valid one ref_clk
//   edge after the sample.
// Date: 2026-10-09
`timescale 1ns/1ps
`ifdef SYNTHESIS
(* blackbox *)
module dpll_dco #(
  parameter int              NOUT         = 1,
  parameter int              CW           = 24,
  parameter int              PW           = 32,
  parameter int              TDC_F        = 8,
  parameter longint          F_MIN_KHZ    = 400_000,
  parameter longint          F_MAX_KHZ    = 1_600_000,
  parameter logic [16*NOUT-1:0] O         = {NOUT{16'd1}},
  parameter int              MISMATCH_PPM = 0
) (
  input  logic            ref_clk,
  input  logic [CW-1:0]   code_i,
  input  logic [NOUT-1:0] en_i,
  output logic [PW-1:0]   phase_o,
  output logic [NOUT-1:0] clk_o
);
endmodule
`else
module dpll_dco #(
  parameter int              NOUT         = 1,
  parameter int              CW           = 24,          // tuning word width
  parameter int              PW           = 32,          // phase read-out width
  parameter int              TDC_F        = 8,           // fractional phase bits
  parameter longint          F_MIN_KHZ    = 400_000,     // frequency at code 0
  parameter longint          F_MAX_KHZ    = 1_600_000,   // frequency at code 2**CW
  parameter logic [16*NOUT-1:0] O         = {NOUT{16'd1}}, // output dividers, [16n +: 16] = output n
  parameter int              MISMATCH_PPM = 0            // oscillator gain error (model only)
) (
  input  logic            ref_clk,
  input  logic [CW-1:0]   code_i,
  input  logic [NOUT-1:0] en_i,
  output logic [PW-1:0]   phase_o,
  output logic [NOUT-1:0] clk_o
);
  initial begin
    if (F_MAX_KHZ <= F_MIN_KHZ || F_MIN_KHZ <= 0) $error("dpll_dco: need 0 < F_MIN_KHZ < F_MAX_KHZ");
    for (int n = 0; n < NOUT; n++)
      if (O[16*n +: 16] == 0) $error("dpll_dco: divider O[%0d] must be >= 1", n);
  end

  // half period of the oscillator in ns for a tuning word (unknown word: mid scale)
  function automatic real half_ns(input logic [CW-1:0] c);
    real f_khz;
    if ($isunknown(c)) f_khz = (F_MIN_KHZ + F_MAX_KHZ) / 2.0;
    else f_khz = F_MIN_KHZ + (F_MAX_KHZ - F_MIN_KHZ) * (c / (2.0 ** CW));
    f_khz = f_khz * (1.0 + MISMATCH_PPM / 1.0e6);
    return 0.5e6 / f_khz;
  endfunction

  // Oscillator phase in half periods: h(t) = h_a + (t - t_a) / th (anchor t_a, h_a)
  real t_a = 0.0, h_a = 0.0, th;
  function automatic real h_now();
    return h_a + ($realtime - t_a) / th;
  endfunction
  // move the anchor to now and apply the current tuning word (phase continuous)
  task automatic retune();
    h_a = h_now();
    t_a = $realtime;
    th  = half_ns(code_i);
  endtask

  initial begin
    th = half_ns(code_i);
    clk_o = '0;
  end

  // Edge scheduler: every output toggles each O[n] oscillator half periods
  longint h_ev = 0;                                 // half period of the last output edge
  always begin : sched
    real hn, h, d;
    longint k, best;
    bit any;
    any = 0;
    for (int n = 0; n < NOUT; n++) if (en_i[n] || clk_o[n]) any = 1;
    if (!any) begin
      @(en_i or code_i);
      retune();
    end else begin
      h = h_now();
      if (h < h_ev) h = h_ev;                         // never schedule at or before the last edge
      best = -1;
      for (int n = 0; n < NOUT; n++) if (en_i[n] || clk_o[n]) begin
        k = (longint'($floor(h / O[16*n +: 16] + 1.0e-9)) + 1) * O[16*n +: 16];  // next multiple after h
        if (best < 0 || k < best) best = k;
      end
      hn = best;
      d  = t_a + (hn - h_a) * th - $realtime;
      #(d);
      // ideal edge time as the new anchor (no accumulation of the delay rounding)
      t_a = t_a + (hn - h_a) * th;
      h_a = hn;
      h_ev = best;
      for (int n = 0; n < NOUT; n++)
        if (best % O[16*n +: 16] == 0) begin
          // rising edges on multiples of 2 O[n] half periods: aligned across outputs
          if (best % (2 * O[16*n +: 16]) == 0) clk_o[n] = en_i[n];
          else clk_o[n] = 1'b0;
        end
      th = half_ns(code_i);
    end
  end

  // Phase read-out: counter (integer cycles) + TDC (TDC_F fractional bits)
  always @(posedge ref_clk) begin : tdc
    real ph;
    ph = h_now() * (2.0 ** (TDC_F - 1));            // half periods -> cycles * 2**TDC_F
    ph = ph - $floor(ph / (2.0 ** PW)) * (2.0 ** PW);
    phase_o <= PW'(longint'($floor(ph)));
  end
endmodule
`endif
