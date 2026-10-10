// ***************
// Filename: dpll_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for dpll. Two instances on a 50 MHz
//   reference: u_int (x16, outputs /4 /8 /5, oscillator +3 % off) and
//   u_frac (x25/3, outputs /2 /3, oscillator -2 % off). Checks lock within
//   the expected time, the exact long-term output frequency (edges counted
//   over a reference window), phase alignment of related outputs
//   (coincident edges), the 50 % duty of an odd divider, glitch-free output
//   gating (en_i) and relock after a loop reset. Prints TEST PASSED on
//   success. The test tasks are in tests/dpll_tests.sv (`included).
// Date: 2026-10-09
`timescale 1ns/1ps
module dpll_tb;
  logic ref_clk = 0;
  always #10 ref_clk = ~ref_clk;                     // 50 MHz
  logic rst_n = 0;
  logic [2:0] en_i = '1;
  wire  [2:0] ck_i;
  wire  [1:0] ck_f;
  wire  lk_i, lk_f;
  // free-running rising-edge counters: outputs 0-2 of u_int, 3-4 of u_frac
  int ec[5] = '{0, 0, 0, 0, 0};
  always @(posedge ck_i[0]) ec[0]++;
  always @(posedge ck_i[1]) ec[1]++;
  always @(posedge ck_i[2]) ec[2]++;
  always @(posedge ck_f[0]) ec[3]++;
  always @(posedge ck_f[1]) ec[4]++;
  // monitors: time of the last /4 rising edge, shortest /4 high pulse
  realtime t4 = -1, r4 = 0, minhi = 1e9;
  always @(posedge ck_i[0]) begin
    t4 = $realtime;
    r4 = $realtime;
  end
  always @(negedge ck_i[0]) if ($realtime - r4 < minhi) minhi = $realtime - r4;
  dpll #(
    .REF_KHZ(50_000),
    .M(16),
    .D(1),
    .NOUT(3),
    .O({16'd5, 16'd8, 16'd4}),
    .F_MIN_KHZ(400_000),
    .F_MAX_KHZ(1_600_000),
    .MISMATCH_PPM(30_000)
  ) u_int (
    .ref_clk,
    .rst_n,
    .en_i,
    .clk_o(ck_i),
    .locked_o(lk_i)
  );
  dpll #(
    .REF_KHZ(50_000),
    .M(25),
    .D(3),
    .NOUT(2),
    .O({16'd3, 16'd2}),
    .F_MIN_KHZ(200_000),
    .F_MAX_KHZ(800_000),
    .MISMATCH_PPM(-20_000)
  ) u_frac (
    .ref_clk,
    .rst_n,
    .en_i(2'b11),
    .clk_o(ck_f),
    .locked_o(lk_f)
  );
  int errors = 0;
  // test tasks: tests/dpll_tests.sv
  `include "dpll_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("dpll_tb.vcd");
      $dumpvars(0, dpll_tb);
    end
    repeat (4) @(posedge ref_clk);
    rst_n <= 1;
    test_lock();
    test_frequency();
    test_alignment();
    test_duty();
    test_gating();
    test_relock();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #2ms;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
