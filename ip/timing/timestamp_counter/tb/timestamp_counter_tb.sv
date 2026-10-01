// ***************
// Filename: timestamp_counter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for timestamp_counter. Checks free-
//   running increment, tick gating, clear, load, coherent capture (value
//   equals the count at the capture clock even while counting) and wrap
//   pulse on a small counter. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module timestamp_counter_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic tick = 1, clr = 0, ld = 0, cap = 0; logic [63:0] lv = 0, cnt, cv; logic cvv, wr;
  timestamp_counter #(.WIDTH(64)) dut (.clk, .rst_n, .tick_i(tick), .clear_i(clr), .load_i(ld), .load_val_i(lv), .capture_i(cap), .count_o(cnt), .capture_o(cv), .cap_valid_o(cvv), .wrap_o(wr));
  logic [3:0] c4, cv4; logic cvv4, wr4; int wraps = 0;
  timestamp_counter #(.WIDTH(4)) d4 (.clk, .rst_n, .tick_i(1'b1), .clear_i(1'b0), .load_i(1'b0), .load_val_i(4'd0), .capture_i(1'b0), .count_o(c4), .capture_o(cv4), .cap_valid_o(cvv4), .wrap_o(wr4));
  always @(posedge clk) if (wr4) wraps++;
  int errors = 0; logic [63:0] snap;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("timestamp_counter_tb.vcd"); $dumpvars(0, timestamp_counter_tb); end
    repeat (3) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk); #1; check(cnt == 10 || cnt == 11, $sformatf("count %0d", cnt));
    tick = 0; snap = cnt; repeat (5) @(posedge clk); #1 check(cnt == snap, "counted with tick low"); tick = 1;
    ld = 1; lv = 64'hFFFF_FFFF_FFFF_FFF0; @(posedge clk); #1 ld = 0; check(cnt == 64'hFFFF_FFFF_FFFF_FFF0, "load");
    repeat (20) @(posedge clk); #1; check(cnt == 4 + 64'd0 || cnt < 10, $sformatf("64 bit wrap %h", cnt));
    // capture: value equals count at the capture edge
    @(posedge clk); #1 cap = 1; snap = cnt; @(posedge clk); #1 cap = 0; check(cvv == 1, "cap_valid"); check(cv == snap, $sformatf("capture %h exp %h", cv, snap));
    @(posedge clk); #1 check(cvv == 0, "cap_valid stuck");
    clr = 1; @(posedge clk); #1 clr = 0; check(cnt == 0, "clear");
    repeat (40) @(posedge clk); check(wraps >= 2, $sformatf("4-bit wraps %0d", wraps));
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #500000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
