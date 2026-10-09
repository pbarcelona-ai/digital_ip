// ***************
// Filename: parity_gen_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for parity_gen. Exhaustive check of
//   all 10-bit words for even and odd parity, combinational and registered
//   (one clock latency, reset value). Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module parity_gen_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [9:0] d = 0;
  logic pe, po, pre, pro;
  parity_gen #(.WIDTH(10), .ODD(0)) ue (
    .clk,
    .rst_n,
    .data_i(d),
    .parity_o(pe)
  );
  parity_gen #(.WIDTH(10), .ODD(1)) uo (
    .clk,
    .rst_n,
    .data_i(d),
    .parity_o(po)
  );
  parity_gen #(.WIDTH(10), .ODD(0), .REGISTERED(1)) ure (
    .clk,
    .rst_n,
    .data_i(d),
    .parity_o(pre)
  );
  parity_gen #(.WIDTH(10), .ODD(1), .REGISTERED(1)) uro (
    .clk,
    .rst_n,
    .data_i(d),
    .parity_o(pro)
  );
  int errors = 0;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("parity_gen_tb.vcd");
      $dumpvars(0, parity_gen_tb);
    end
    repeat (3) @(posedge clk);
    #1;
    if (pre !== 1'b0 || pro !== 1'b1) begin
      errors++;
      $display("ERROR reset values");
    end
    rst_n = 1;
    for (int i = 0; i < 1024; i++) begin
      logic e;
      e = ^i[9:0];
      @(posedge clk);
      #1 d = i;
      #1;
      if (pe !== e || po !== ~e) begin
        errors++;
        $display("ERROR word %h", i);
      end
      @(posedge clk);
      #1;
      if (pre !== e || pro !== ~e) begin
        errors++;
        $display("ERROR registered word %h", i);
      end
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
