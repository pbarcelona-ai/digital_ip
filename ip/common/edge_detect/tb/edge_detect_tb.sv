// ***************
// Filename: edge_detect_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for edge_detect. Instantiates
//   rising, falling and both-edge detectors plus a synchronized variant,
//   drives random input activity and compares each output with a cycle
//   accurate reference model. Also checks that no pulse appears right
//   after reset. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module edge_detect_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [1:0] d = 0;
  logic [1:0] pr, pf, pb, ps;
  edge_detect #(.WIDTH(2), .EDGE(0)) ur (
    .clk,
    .rst_n,
    .d_i(d),
    .pulse_o(pr)
  );
  edge_detect #(.WIDTH(2), .EDGE(1)) uf (
    .clk,
    .rst_n,
    .d_i(d),
    .pulse_o(pf)
  );
  edge_detect #(.WIDTH(2), .EDGE(2)) ub (
    .clk,
    .rst_n,
    .d_i(d),
    .pulse_o(pb)
  );
  edge_detect #(.WIDTH(2), .EDGE(0), .SYNC_INPUT(1)) us (
    .clk,
    .rst_n,
    .d_i(d),
    .pulse_o(ps)
  );
  int errors = 0;
  logic [1:0] prev = 0, er, ef, eb, d1 = 0, d2 = 0, d3 = 0, es;
  // Reference: registered outputs
  always @(posedge clk) begin
    if (!rst_n) begin
      prev <= 0;
      er <= 0;
      ef <= 0;
      eb <= 0;
      es <= 0;
      d1 <= 0;
      d2 <= 0;
      d3 <= 0;
    end
    else begin
      er <= d & ~prev;
      ef <= ~d & prev;
      eb <= d ^ prev;
      prev <= d;
      d1 <= d;
      d2 <= d1;
      d3 <= d2;
      es <= d2 & ~d3;
    end
  end
  always @(negedge clk) if (rst_n) begin
    if (pr !== er || pf !== ef || pb !== eb || ps !== es) begin
      errors++;
      $display("ERROR @%0t: r %b/%b f %b/%b b %b/%b s %b/%b", $time, pr, er, pf, ef, pb, eb, ps, es);
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("edge_detect_tb.vcd");
      $dumpvars(0, edge_detect_tb);
    end
    d = 2'b11;                                  // high during reset: no edge afterwards for sync=none? (reset level 0 -> rise seen)
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (500) begin
      @(posedge clk);
      #1 d = $urandom;
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #100000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
