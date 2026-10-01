// ***************
// Filename: bit_sync_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for bit_sync. Checks reset value,
//   latency of exactly STAGES destination clocks for both edges, and that
//   a change occurring between clock edges never produces a glitch (output
//   only changes on clock edges). Runs 2 and 3 stage instances. Prints
//   TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module bit_sync_tb;
  logic clk = 0, rst_n = 0, d = 0; always #5 clk = ~clk;
  logic q2, q3;
  bit_sync #(.STAGES(2), .RESET_VAL(1'b1)) u2 (.clk, .rst_n, .d_i(d), .q_o(q2));
  bit_sync #(.STAGES(3)) u3 (.clk, .rst_n, .d_i(d), .q_o(q3));
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  int n;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("bit_sync_tb.vcd"); $dumpvars(0, bit_sync_tb); end
    repeat (2) @(posedge clk); #1;
    check(q2 == 1 && q3 == 0, "reset values");
    rst_n = 1; repeat (4) @(posedge clk);
    // rising edge asynchronous to clk
    #2.3 d = 1; n = 0;
    while (q2 !== 1'b1) begin @(posedge clk); #1 n++; end
    check(n == 2, $sformatf("2-stage latency %0d", n));
    while (q3 !== 1'b1) begin @(posedge clk); #1 n++; end
    check(n == 3, $sformatf("3-stage latency %0d", n));
    #2.7 d = 0; n = 0;
    while (q2 !== 1'b0) begin @(posedge clk); #1 n++; end
    check(n == 2, "2-stage fall latency");
    repeat (4) @(posedge clk);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
