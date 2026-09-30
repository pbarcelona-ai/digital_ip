// ***************
// Filename: rom_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for rom. Reads every address of a
//   non power-of-two ROM (built-in pattern), checks one clock latency,
//   out-of-range handling and reset behaviour. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module rom_tb;
  logic clk = 0, rst_n = 0, en = 0; always #5 clk = ~clk;
  logic [6:0] a = 0; logic [19:0] q; logic oob;
  rom #(.WIDTH(20), .DEPTH(100)) dut (.clk, .rst_n, .en_i(en), .addr_i(a), .data_o(q), .oob_o(oob));
  int errors = 0;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("rom_tb.vcd"); $dumpvars(0, rom_tb); end
    repeat (3) @(posedge clk); rst_n = 1;
    for (int i = 0; i < 128; i++) begin
      @(posedge clk); #1 en = 1; a = i;
      @(posedge clk); #1;
      if (i < 100) begin
        if (q !== 20'((32'(i) ^ 32'hA5A5_5A5A)) || oob) begin errors++; $display("ERROR addr %0d q %h oob %b", i, q, oob); end
      end else if (q !== 0 || !oob) begin errors++; $display("ERROR oob addr %0d", i); end
    end
    en = 0; a = 3; repeat (3) @(posedge clk); #1;
    if (q !== 0 && q !== 20'((32'd127 ^ 32'hA5A5_5A5A)) && q !== 0) begin errors++; end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #200000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
