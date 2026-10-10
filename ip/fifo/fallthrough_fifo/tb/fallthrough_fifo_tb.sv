// ***************
// Filename: fallthrough_fifo_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for fallthrough_fifo. Random
//   valid/ready traffic checked against a scoreboard queue (order, data,
//   no loss), verifies the first word appears on the output without a read
//   request and that s_ready deasserts when full. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module fallthrough_fifo_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [15:0] sd = 0, md;
  logic sv = 0, sr, mv, mr = 0;
  logic [3:0] lvl;
  fallthrough_fifo #(
    .WIDTH(16),
    .DEPTH(8)
  ) dut (
    .clk,
    .rst_n,
    .s_data_i(sd),
    .s_valid_i(sv),
    .s_ready_o(sr),
    .m_data_o(md),
    .m_valid_o(mv),
    .m_ready_i(mr),
    .level_o(lvl)
  );
  int errors = 0, full_seen = 0, n = 0;
  bit rand_en = 0;
  logic [15:0] q[$];
  always @(posedge clk) if (rst_n) begin
    if (sv && sr) q.push_back(sd);
    if (mv && q.size() == 0) begin
      errors++;
      $display("ERROR valid with no data");
    end
    if (mv && mr) begin
      if (q.size() == 0 || md !== q[0]) begin
        errors++;
        $display("ERROR pop %h exp %h", md, q.size() ? q[0] : 16'hx);
      end
      else void'(q.pop_front());
    end
    if (!sr) full_seen++;
  end
  always @(posedge clk) if (rst_n && rand_en) begin
    #1 sv = ($urandom_range(0, 9) < (n < 500 ? 8 : 4));
    sd = $urandom;
    mr = ($urandom_range(0, 9) < (n < 500 ? 2 : 7));
    n++;
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("fallthrough_fifo_tb.vcd");
      $dumpvars(0, fallthrough_fifo_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    // first-word fall-through: write one word into an empty FIFO with no read
    @(posedge clk);
    #1 sv = 1;
    sd = 16'h5A5A;
    @(posedge clk);
    #1 sv = 0;
    if (!(mv && md == 16'h5A5A)) begin
      errors++;
      $display("ERROR first word not presented");
    end
    rand_en = 1;
    repeat (3000) @(posedge clk);
    if (full_seen == 0) begin
      errors++;
      $display("ERROR never full");
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
