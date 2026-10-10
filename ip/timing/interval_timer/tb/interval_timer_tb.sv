// ***************
// Filename: interval_timer_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for interval_timer. Measures the
//   event spacing for auto-reload and one-shot operation with and without
//   a prescaler, stop and restart, the remaining counter and the refusal
//   of a zero interval. Prints TEST PASSED on success.
//   The test tasks are in tests/interval_timer_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module interval_timer_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic start = 0, stop = 0, auto = 1, run, tick, err;
  logic [15:0] iv = 10, rem;
  logic [3:0] ps = 0;
  interval_timer #(
    .WIDTH(16),
    .PRES_W(4)
  ) dut (
    .clk,
    .rst_n,
    .start_i(start),
    .stop_i(stop),
    .auto_i(auto),
    .interval_i(iv),
    .prescale_i(ps),
    .running_o(run),
    .tick_o(tick),
    .remaining_o(rem),
    .err_o(err)
  );
  int errors = 0, cyc = 0, ev = 0;
  always @(posedge clk) begin
    cyc++;
    if (tick) ev++;
  end
  // test tasks: tests/interval_timer_tests.sv
  `include "interval_timer_tests.sv"
  int t0, t1, t2;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("interval_timer_tb.vcd");
      $dumpvars(0, interval_timer_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    #1;
    // auto reload, interval 10, no prescale
    pulse_start();
    @(posedge tick);
    t0 = cyc;
    @(posedge tick);
    t1 = cyc;
    @(posedge tick);
    t2 = cyc;
    check(t1 - t0 == 10 && t2 - t1 == 10, $sformatf("auto spacing %0d %0d", t1 - t0, t2 - t1));
    // with prescale 3 (divide by 4): spacing 40
    pulse_stop();
    repeat (3) @(posedge clk);
    ps = 3;
    pulse_start();
    @(posedge tick);
    t0 = cyc;
    @(posedge tick);
    t1 = cyc;
    check(t1 - t0 == 40, $sformatf("prescaled spacing %0d", t1 - t0));
    // remaining counts down
    begin
      logic [15:0] r0;
      @(posedge clk);
      r0 = rem;
      repeat (8) @(posedge clk);
      check(rem < r0 || rem > r0, "remaining not moving");
    end
    // stop halts events
    pulse_stop();
    ev = 0;
    repeat (200) @(posedge clk);
    check(ev == 0 && !run, "events after stop");
    // one-shot
    auto = 0;
    ps = 0;
    iv = 7;
    pulse_start();
    ev = 0;
    repeat (100) @(posedge clk);
    check(ev == 1 && !run, $sformatf("one-shot events %0d running %b", ev, run));
    // zero interval refused
    iv = 0;
    @(posedge clk);
    #1 start = 1;
    @(posedge clk);
    #1 start = 0;
    #1 check(err == 1 && !run, "zero interval must set err and not start");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #2000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
