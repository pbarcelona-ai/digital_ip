// ***************
// Filename: error_status_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for error_status. Checks sticky
//   set, W1C-style clear, error-wins-over-clear, clear-all, irq masking,
//   first-error index capture and hold, saturating error counter and reset
//   state. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module error_status_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic [7:0] err = 0, clr = 0, im = 0, st; logic ca = 0, fv, irq; logic [2:0] fi; logic [3:0] cnt;
  error_status #(.NERR(8), .CNT_W(4)) dut (.clk, .rst_n, .err_i(err), .clr_mask_i(clr), .clr_all_i(ca), .irq_mask_i(im), .status_o(st), .first_idx_o(fi), .first_valid_o(fv), .count_o(cnt), .irq_o(irq));
  int errors = 0;
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end endtask
  task automatic pulse_err(input logic [7:0] e); @(posedge clk); #1 err = e; @(posedge clk); #1 err = 0; endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("error_status_tb.vcd"); $dumpvars(0, error_status_tb); end
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk); #1;
    check(st == 0 && !fv && cnt == 0 && !irq, "reset state");
    pulse_err(8'b0010_0100); check(st == 8'b0010_0100, "sticky set"); check(fv && fi == 2, $sformatf("first idx %0d", fi));
    pulse_err(8'b0000_0001); check(st == 8'b0010_0101 && fi == 2, "first index must hold");
    im = 8'b1000_0000; #1 check(!irq, "irq masked"); im = 8'b0000_0100; #1 check(irq, "irq enabled");
    @(posedge clk); #1 clr = 8'b0000_0100; @(posedge clk); #1 clr = 0; check(st == 8'b0010_0001 && !irq, "clear bit 2");
    // error and clear in the same clock: error wins
    @(posedge clk); #1 clr = 8'b0010_0000; err = 8'b0010_0000; @(posedge clk); #1 clr = 0; err = 0; check(st[5] == 1, "error must win over clear");
    check(cnt == 3, $sformatf("count %0d", cnt));
    // saturate counter (4 bit)
    for (int i = 0; i < 30; i++) pulse_err(8'b0100_0000); check(cnt == 15, "counter saturation");
    @(posedge clk); #1 ca = 1; @(posedge clk); #1 ca = 0; check(st == 0 && !fv && cnt == 0, "clear all");
    pulse_err(8'b1000_0000); check(fv && fi == 7 && st == 8'h80 && cnt == 1, "capture after clear");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #500000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
