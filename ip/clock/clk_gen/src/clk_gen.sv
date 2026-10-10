// ***************
// Filename: clk_gen.sv
// Author: FPGA Cores 4 U
// Description: Clock generator: one reference clock in, a CPU clock and
//   NCLK further clocks out, every ratio set by parameters. Version 1.0.0.
//     u_pll_cpu  dpll  ref_clk -> oscillator REF * CPU_M / CPU_D ->
//                      cpu_clk_o = oscillator / CPU_O (a clock multiplier:
//                      cpu_clk_o may be faster than ref_clk)
//     u_pll_clk  dpll  cpu_clk_o -> oscillator CPU * CLK_M / CLK_D ->
//                      clk_o[n] = oscillator / CLK_O[n]; the outputs share
//                      one oscillator, so related outputs (e.g. a pixel
//                      clock and its 10x serial clock) are phase aligned
//   so f(clk_o[n]) = REF_KHZ * CPU_M * CLK_M / (CPU_D * CPU_O * CLK_D *
//   CLK_O[n]). The second loop starts once the CPU loop is locked (it
//   uses cpu_clk_o as its reference). clk_en_i[n] gates clk_o[n] glitch
//   free (the output finishes its high phase, then stays low).
//   Synthesis: each dpll's oscillator (dpll_dco) is a black box; the loop
//   logic (dpll_ctrl) and the reset / lock logic here are synthesizable.
//   On an FPGA, replace u_pll_cpu / u_pll_clk with the device PLL / MMCM
//   and BUFGCE outputs (same ports, same ratios).
//   Clocks - ref_clk in; cpu_clk_o, clk_o out. Reset - arst_n,
//   asynchronous, active low (both loops restart; the oscillators keep
//   running). Status - cpu_locked_o (cpu_clk_o domain, asserts low at
//   once on loss of lock, released two cpu_clk_o edges after lock: use it
//   as the CPU reset), clk_locked_o (cpu_clk_o domain, both loops locked).
//   clk_en_i is in the cpu_clk_o domain.
// Date: 2026-10-09
module clk_gen #(
  // Defaults (video_processor): 33.333 MHz reference -> CPU 200 MHz -> 7 GHz video oscillator ->
  // core / pixel 100 MHz, TMDS 1 GHz (10x), LVDS 700 MHz (7x), MIPI byte 125 MHz
  parameter longint REF_KHZ          = 33_333,       // reference clock frequency
  // CPU clock: REF_KHZ * CPU_M / (CPU_D * CPU_O)
  parameter int     CPU_M            = 24,
  parameter int     CPU_D            = 1,
  parameter int     CPU_O            = 4,
  parameter longint CPU_VCO_MIN_KHZ  = 400_000,
  parameter longint CPU_VCO_MAX_KHZ  = 1_600_000,
  // Output clocks: CPU clock * CLK_M / (CLK_D * CLK_O[n]), CLK_O[16n +: 16] for output n
  parameter int     NCLK             = 4,
  parameter int     CLK_M            = 35,
  parameter int     CLK_D            = 1,
  parameter logic [16*NCLK-1:0] CLK_O = {16'd56, 16'd10, 16'd7, 16'd70},
  parameter longint CLK_VCO_MIN_KHZ  = 2_500_000,
  parameter longint CLK_VCO_MAX_KHZ  = 7_500_000,
  // oscillator errors of the simulation model (the loops correct them)
  parameter int     CPU_MISMATCH_PPM = 0,
  parameter int     CLK_MISMATCH_PPM = 0
) (
  input  logic            ref_clk,
  input  logic            arst_n,
  input  logic [NCLK-1:0] clk_en_i,
  output logic            cpu_clk_o,
  output logic [NCLK-1:0] clk_o,
  output logic            cpu_locked_o,
  output logic            clk_locked_o
);
  localparam longint CPU_KHZ = REF_KHZ * CPU_M / (CPU_D * CPU_O);

  // ---------------- CPU clock: reference x CPU_M / CPU_D / CPU_O ----------------
  logic ref_rst_n, lock_cpu;
  reset_sync u_rst_ref (
    .clk(ref_clk),
    .arst_i(arst_n),
    .rst_o(ref_rst_n)
  );
  dpll #(
    .REF_KHZ(REF_KHZ),
    .M(CPU_M),
    .D(CPU_D),
    .NOUT(1),
    .O(16'(CPU_O)),
    .F_MIN_KHZ(CPU_VCO_MIN_KHZ),
    .F_MAX_KHZ(CPU_VCO_MAX_KHZ),
    .MISMATCH_PPM(CPU_MISMATCH_PPM)
  ) u_pll_cpu (
    .ref_clk,
    .rst_n(ref_rst_n),
    .en_i(1'b1),
    .clk_o(cpu_clk_o),
    .locked_o(lock_cpu)
  );
  // lock into the CPU clock domain: immediate on loss, synchronous release
  wire cpu_ok = arst_n & lock_cpu;
  reset_sync u_lock_cpu (
    .clk(cpu_clk_o),
    .arst_i(cpu_ok),
    .rst_o(cpu_locked_o)
  );

  // ---------------- output clocks: CPU clock x CLK_M / CLK_D / CLK_O[n] ----------------
  logic lock_clk;
  dpll #(
    .REF_KHZ(CPU_KHZ),
    .M(CLK_M),
    .D(CLK_D),
    .NOUT(NCLK),
    .O(CLK_O),
    .F_MIN_KHZ(CLK_VCO_MIN_KHZ),
    .F_MAX_KHZ(CLK_VCO_MAX_KHZ),
    .MISMATCH_PPM(CLK_MISMATCH_PPM)
  ) u_pll_clk (
    .ref_clk(cpu_clk_o),
    .rst_n(cpu_locked_o),
    .en_i(clk_en_i),
    .clk_o,
    .locked_o(lock_clk)
  );
  assign clk_locked_o = cpu_locked_o & lock_clk;
endmodule
