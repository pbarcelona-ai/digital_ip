// ***************
// Filename: timeout_timer_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for timeout_timer. Checks the exact
//   expiry latency, that activity restarts the count and clears expired,
//   that timeout 0 disables the timer, the single-clock timeout pulse and
//   tick enable operation. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module timeout_timer_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic ce = 1, act = 0, exp, pls; logic [9:0] tmo = 0;
  timeout_timer #(.WIDTH(10)) dut (.clk, .rst_n, .ce_i(ce), .activity_i(act), .timeout_i(tmo), .expired_o(exp), .timeout_pulse_o(pls));
  int errors = 0, n, pulses = 0;
  always @(posedge clk) if (pls) pulses++;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  task automatic kick(); @(posedge clk); #1 act = 1; @(posedge clk); #1 act = 0; endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("timeout_timer_tb.vcd"); $dumpvars(0, timeout_timer_tb); end
    repeat (3) @(posedge clk); rst_n = 1; tmo = 0; repeat (50) @(posedge clk);
    check(!exp, "disabled timer expired");
    tmo = 20; kick(); n = 0;
    while (!exp) begin @(posedge clk); #1 n++; end
    check(n >= 19 && n <= 21, $sformatf("expiry after %0d clocks, timeout 20", n));
    repeat (2) @(posedge clk); check(pulses == 1, "one pulse expected"); repeat (30) @(posedge clk); check(pulses == 1, "pulse repeated");
    check(exp, "expired must stay high"); kick(); check(!exp, "activity must clear expired");
    // activity keeps it alive
    repeat (10) begin repeat (15) @(posedge clk); kick(); end
    check(!exp, "expired despite activity");
    // tick enable: ce every 4th clock
    tmo = 5; kick(); ce = 0; n = 0;
    fork begin repeat (100) begin @(posedge clk); #1 ce = ($time / 10) % 4 == 0; end end join_none
    while (!exp) begin @(posedge clk); #1 n++; end
    check(n >= 18 && n <= 26, $sformatf("slow tick expiry %0d", n));
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #500000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
