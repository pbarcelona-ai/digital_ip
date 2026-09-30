// ***************
// Filename: register_file_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for register_file. Random writes
//   and dual port reads against a reference model in plain, bypass and
//   zero-register-0 configurations, plus reset clearing. Prints TEST
//   PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module rf_case #(parameter bit Z = 0, parameter bit BY = 0) (input logic clk, input logic rst_n, output int errors);
  logic we; logic [3:0] wa, r0, r1; logic [15:0] wd; logic [31:0] rd;
  register_file #(.WIDTH(16), .NREG(16), .NRD(2), .ZERO_REG0(Z), .BYPASS(BY)) dut
    (.clk, .rst_n, .we_i(we), .waddr_i(wa), .wdata_i(wd), .raddr_i({r1, r0}), .rdata_o(rd));
  logic [15:0] m [0:15];
  initial begin errors = 0; we = 0; wa = 0; wd = 0; r0 = 0; r1 = 0; for (int i = 0; i < 16; i++) m[i] = 0; end
  always @(posedge clk) begin
    if (!rst_n) for (int i = 0; i < 16; i++) m[i] <= 0;
    else if (we && !(Z && wa == 0)) m[wa] <= wd;
    if (rst_n) begin #1 we = $urandom_range(0, 1); wa = $urandom; wd = $urandom; r0 = $urandom; r1 = $urandom; end
  end
  always @(negedge clk) if (rst_n) begin
    logic [15:0] e0, e1; e0 = (Z && r0 == 0) ? 0 : (BY && we && r0 == wa && !(Z && wa == 0)) ? wd : m[r0];
    e1 = (Z && r1 == 0) ? 0 : (BY && we && r1 == wa && !(Z && wa == 0)) ? wd : m[r1];
    if (rd[15:0] !== e0 || rd[31:16] !== e1) begin errors++; $display("ERROR z%0d by%0d: %h/%h %h/%h", Z, BY, rd[15:0], e0, rd[31:16], e1); end
  end
endmodule
module register_file_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int e0, e1, e2;
  rf_case #(0, 0) a (clk, rst_n, e0);
  rf_case #(0, 1) b (clk, rst_n, e1);
  rf_case #(1, 1) c (clk, rst_n, e2);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("register_file_tb.vcd"); $dumpvars(0, register_file_tb); end
    repeat (3) @(posedge clk); rst_n = 1; repeat (2000) @(posedge clk); #2;
    if (e0 + e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end
endmodule
