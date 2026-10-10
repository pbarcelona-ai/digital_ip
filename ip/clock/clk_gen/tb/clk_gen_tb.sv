// ***************
// Filename: clk_gen_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for clk_gen in its default
//   (video_processor) configuration: 33.333 MHz reference, CPU x24 / 4 =
//   200 MHz (oscillator +2 %), output loop x35 = 7 GHz (oscillator -3 %)
//   divided by 70 / 7 / 10 / 56 = core / pixel 100 MHz, TMDS 1 GHz (10x),
//   LVDS 700 MHz (7x), MIPI byte 125 MHz. Checks the lock sequence (CPU
//   loop first, then the output loop), the exact long-term frequencies,
//   the phase alignment of
//   the serial clocks with the pixel clock (every pixel rising edge is a
//   TMDS and an LVDS rising edge), glitch-free output enables, and loss of
//   lock and relock on arst_n. Prints TEST PASSED on success.
//   The test tasks are in tests/clk_gen_tests.sv (`included).
// Date: 2026-10-09
`timescale 1ns/1ps
module clk_gen_tb;
  logic ref_clk = 0;
  always #15 ref_clk = ~ref_clk;                     // 33.333 MHz
  logic arst_n = 0;
  logic [3:0] en = '1;
  wire  cpu_clk, cpu_locked, clk_locked;
  wire  [3:0] ck;                                    // pixel, TMDS, LVDS, byte
  clk_gen #(
    .CPU_MISMATCH_PPM(20_000),
    .CLK_MISMATCH_PPM(-30_000)
  ) dut (     // default ratios
    .ref_clk,
    .arst_n,
    .clk_en_i(en),
    .cpu_clk_o(cpu_clk),
    .clk_o(ck),
    .cpu_locked_o(cpu_locked),
    .clk_locked_o(clk_locked)
  );
  // free-running rising-edge counters: CPU, pixel, TMDS, LVDS, byte
  int ec[5] = '{0, 0, 0, 0, 0};
  always @(posedge cpu_clk) ec[0]++;
  always @(posedge ck[0]) ec[1]++;
  always @(posedge ck[1]) ec[2]++;
  always @(posedge ck[2]) ec[3]++;
  always @(posedge ck[3]) ec[4]++;
  // last rising edge times of the serial clocks, shortest high pulse of the byte clock
  realtime t_tmds = -1, t_lvds = -1, r3 = 0, minhi = 1e9;
  always @(posedge ck[1]) t_tmds = $realtime;
  always @(posedge ck[2]) t_lvds = $realtime;
  always @(posedge ck[3]) r3 = $realtime;
  always @(negedge ck[3]) if ($realtime - r3 < minhi) minhi = $realtime - r3;
  int errors = 0;
  // test tasks: tests/clk_gen_tests.sv
  `include "clk_gen_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("clk_gen_tb.vcd");
      $dumpvars(0, clk_gen_tb);
    end
    #55 arst_n = 1;
    test_lock();
    test_frequency();
    test_alignment();
    test_enable();
    test_reset();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #1ms;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
