// ***************
// Filename: parity_check_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for parity_check. Feeds words with
//   correct parity (must never flag) and with single bit flips in data or
//   parity bit (must always flag), even and odd modes, checks that double
//   flips pass, sticky and counter behaviour, clear and valid
//   qualification. Prints TEST PASSED on success.
//   The test tasks are in tests/parity_check_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module pc_case #(parameter bit ODD = 0) (input logic clk, input logic rst_n, output int errors);
  logic v = 0, clr = 0; logic [7:0] d = 0; logic p = 0, e, s; logic [3:0] c;
  parity_check #(.WIDTH(8), .ODD(ODD), .CNT_W(4)) dut (.clk, .rst_n, .valid_i(v), .data_i(d), .parity_i(p), .clr_i(clr), .err_o(e), .sticky_o(s), .err_count_o(c));
  int flagged = 0;
  // test tasks: tests/parity_check_tests.sv
  `include "parity_check_tests.sv"
  initial begin
    errors = 0; wait (rst_n); repeat (2) @(posedge clk);
    for (int i = 0; i < 64; i++) word($urandom, -1);
    if (s !== 0 || c !== 0) begin errors++; $display("ERROR sticky/count after good words"); end
    for (int f = 0; f < 9; f++) word($urandom, f);
    if (s !== 1 || c !== 9) begin errors++; $display("ERROR sticky %b count %0d exp 9", s, c); end
    word($urandom, 9);
    if (c !== 9) begin errors++; $display("ERROR double flip counted"); end
    for (int i = 0; i < 10; i++) word($urandom, 3);
    if (c !== 15) begin errors++; $display("ERROR counter should saturate at 15, got %0d", c); end
    @(posedge clk); #1 clr = 1; @(posedge clk); #1 clr = 0; @(posedge clk); #1;
    if (s !== 0 || c !== 0) begin errors++; $display("ERROR clear"); end
    // valid qualification: bad word without valid is ignored
    d = 8'h01; p = ODD ? 1'b1 : 1'b0; @(posedge clk); @(posedge clk); #1; if (e !== 0) begin errors++; $display("ERROR flagged without valid"); end
  end
endmodule
module parity_check_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk; int e0, e1;
  pc_case #(0) a (clk, rst_n, e0); pc_case #(1) b (clk, rst_n, e1);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("parity_check_tb.vcd"); $dumpvars(0, parity_check_tb); end
    repeat (3) @(posedge clk); rst_n = 1; #200000;
    if (e0 + e1 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
endmodule
