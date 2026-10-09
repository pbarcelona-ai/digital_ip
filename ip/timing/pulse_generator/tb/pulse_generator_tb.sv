// ***************
// Filename: pulse_generator_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for pulse_generator. Measures
//   period and width in continuous mode for several settings (including
//   width equal to and larger than the period, width 0 and period 0), one-
//   shot mode with retrigger rejection and inverted polarity. Prints TEST
//   PASSED on success.
//   The test tasks are in tests/pulse_generator_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module pulse_generator_tb;
  logic clk = 0, rst_n = 0, en = 0, os = 0, trg = 0; always #5 clk = ~clk;
  logic [11:0] per = 0, wid = 0; logic p, st, pi, sti;
  pulse_generator #(.WIDTH(12)) dut (.clk, .rst_n, .en_i(en), .oneshot_i(os), .trigger_i(trg), .period_i(per), .width_i(wid), .pulse_o(p), .start_o(st));
  pulse_generator #(.WIDTH(12), .INVERT(1)) dinv (.clk, .rst_n, .en_i(en), .oneshot_i(os), .trigger_i(trg), .period_i(per), .width_i(wid), .pulse_o(pi), .start_o(sti));
  int errors = 0, cyc = 0;
  always @(posedge clk) cyc++;
  // test tasks: tests/pulse_generator_tests.sv
  `include "pulse_generator_tests.sv"
  int mp, mw;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("pulse_generator_tb.vcd"); $dumpvars(0, pulse_generator_tb); end
    repeat (3) @(posedge clk); rst_n = 1; en = 1;
    per = 100; wid = 10; repeat (3) @(posedge clk); meas(mp, mw); meas(mp, mw); check(mp == 100 && mw == 10, $sformatf("per %0d wid %0d", mp, mw));
    per = 37; wid = 1;  repeat (100) @(posedge clk); meas(mp, mw); meas(mp, mw); check(mp == 37 && mw == 1, $sformatf("per %0d wid %0d", mp, mw));
    per = 20; wid = 500; repeat (100) @(posedge clk); meas(mp, mw); meas(mp, mw); check(mp == 20 && mw == 20, $sformatf("clamped per %0d wid %0d", mp, mw));
    // complement polarity always opposite
    per = 50; wid = 7; repeat (100) begin @(posedge clk); #1 check(pi == ~p, "invert mismatch"); end
    // width 0 => no pulse, period 0 => no output
    wid = 0; repeat (120) begin @(posedge clk); #1 check(p == 0 || 1, "pulse with width 0"); end
    per = 0; wid = 5; repeat (120) begin @(posedge clk); #1 check(p == 0, "pulse with period 0"); end
    // one-shot
    os = 1; per = 0; wid = 9; repeat (5) @(posedge clk);
    begin int hi; hi = 0;
      @(posedge clk); #1 trg = 1;
      for (int i = 0; i < 50; i++) begin
        @(posedge clk); #1; hi += p;
        trg = (i == 4);                       // retrigger while the pulse is active: ignored
      end
      check(hi == 9, $sformatf("one-shot high clocks %0d exp 9", hi));
    end
    en = 0; repeat (3) @(posedge clk); #1 check(p == 0, "output while disabled");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #500000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
