// ***************
// Filename: reset_sync_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for reset_sync. Checks asynchronous
//   assertion (output active immediately), synchronous release exactly
//   STAGES clocks after arst_i deasserts, the fully synchronous variant,
//   and both polarity options. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module reset_sync_tb;
  logic clk = 0; always #5 clk = ~clk;
  logic arst_n = 0, r_async, r_sync, r_hi;
  reset_sync #(.STAGES(2)) ua (.clk, .arst_i(arst_n), .rst_o(r_async));
  reset_sync #(.STAGES(3), .ASYNC_ASSERT(0)) us (.clk, .arst_i(arst_n), .rst_o(r_sync));
  reset_sync #(.STAGES(2), .ACTIVE_LOW_IN(0), .ACTIVE_LOW_OUT(0)) uh (.clk, .arst_i(~arst_n), .rst_o(r_hi));
  int errors = 0, n;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("reset_sync_tb.vcd"); $dumpvars(0, reset_sync_tb); end
    #12; check(r_async == 0 && r_hi == 1, "asserted during reset");
    // release asynchronously between clock edges
    #3.3 arst_n = 1; n = 0;
    while (r_async == 0) begin @(posedge clk); #1 n++; end
    check(n == 2, $sformatf("release latency %0d exp 2", n));
    while (r_sync == 0) begin @(posedge clk); #1 n++; end
    check(n == 3, $sformatf("sync-variant release latency %0d exp 3", n));
    check(r_hi == 0, "active-high output should be low after release");
    // asynchronous assertion mid-cycle
    #2.2 arst_n = 0; #0.1;
    check(r_async == 0 && r_hi == 1, "async assert must be immediate");
    check(r_sync == 1, "sync variant must not react before clock edge");
    @(posedge clk); #1; check(r_sync == 0, "sync variant asserts at clock edge (STAGES flops clear)");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
