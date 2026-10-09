// ***************
// Filename: clock_enable_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for clock_enable. Measures the
//   pulse spacing for several divide ratios (including 0, 1 and a runtime
//   change), the pulse width, and that disabling stops the pulses. Prints
//   TEST PASSED on success.
//   The test tasks are in tests/clock_enable_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module clock_enable_tb;
  logic clk = 0, rst_n = 0, en = 0;
  always #5 clk = ~clk;
  logic [7:0] div = 5;
  logic ce;
  clock_enable #(.DIV_W(8)) dut (
    .clk,
    .rst_n,
    .en_i(en),
    .div_i(div),
    .ce_o(ce)
  );
  int errors = 0, last, cyc = 0;
  always @(posedge clk) cyc++;
  // test tasks: tests/clock_enable_tests.sv
  `include "clock_enable_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("clock_enable_tb.vcd");
      $dumpvars(0, clock_enable_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    en = 1;
    spacing(5);
    div = 1;
    repeat (3) @(posedge clk);
    check(ce == 1, "div 1 => every clock");
    div = 0;
    repeat (3) @(posedge clk);
    check(ce == 1, "div 0 => every clock");
    div = 200;
    spacing(200);
    div = 3;
    repeat (300) @(posedge clk);
    spacing(3);
    // single-clock width
    @(posedge ce);
    @(posedge clk);
    #1;
    check(ce == 0, "pulse wider than one clock");
    en = 0;
    repeat (5) @(posedge clk);
    #1;
    check(ce == 0, "pulse while disabled");
    repeat (20) begin
      @(posedge clk);
      #1;
      check(ce == 0, "ce while disabled");
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #200000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
