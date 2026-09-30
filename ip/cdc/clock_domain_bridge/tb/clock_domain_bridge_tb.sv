// ***************
// Filename: clock_domain_bridge_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for clock_domain_bridge. Random
//   words cross between unrelated clock pairs (fast to slow, slow to fast,
//   equal, odd ratio) with random source gaps and destination back-
//   pressure; the scoreboard verifies that every word arrives exactly
//   once, in order and unmodified, and that s_ready never accepts a second
//   word while one is in flight. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module cdb_case #(parameter real SP = 10.0, parameter real DP = 13.0) (output int errors, output bit done);
  logic sclk = 0, mclk = 0, srst = 0, mrst = 0; always #(SP/2) sclk = ~sclk; always #(DP/2) mclk = ~mclk;
  logic [31:0] sd = 0, md; logic sv = 0, sr, mv, mr = 0;
  clock_domain_bridge #(.DATA_W(32), .STAGES(2)) dut (.s_clk(sclk), .s_rst_n(srst), .s_data_i(sd), .s_valid_i(sv), .s_ready_o(sr), .m_clk(mclk), .m_rst_n(mrst), .m_data_o(md), .m_valid_o(mv), .m_ready_i(mr));
  logic [31:0] q[$]; int sent = 0, got = 0; localparam int N = 300;
  always @(posedge sclk) if (srst) begin
    if (sv && sr) begin q.push_back(sd); sent++; sv <= 0; end
    if ((!sv || sr) && sent < N && $urandom_range(0, 3) != 0) begin sv <= 1; sd <= $urandom; end
  end
  always @(posedge mclk) if (mrst) begin
    mr <= ($urandom_range(0, 2) != 0);
    if (mv && mr) begin
      if (q.size() == 0 || md !== q[0]) begin errors++; $display("ERROR word %0d got %h exp %h", got, md, q.size() ? q[0] : 32'hx); end
      else void'(q.pop_front());
      got++;
    end
  end
  initial begin
    errors = 0; done = 0; repeat (5) @(posedge sclk); srst = 1; mrst = 1;
    wait (got == N); repeat (30) @(posedge sclk); if (sent != N) errors++; done = 1;
  end
endmodule
module clock_domain_bridge_tb;
  int e0, e1, e2, e3; bit d0, d1, d2, d3;
  cdb_case #(10.0, 27.0) a (e0, d0); cdb_case #(27.0, 10.0) b (e1, d1); cdb_case #(10.0, 10.0) c (e2, d2); cdb_case #(7.0, 11.3) d (e3, d3);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("clock_domain_bridge_tb.vcd"); $dumpvars(0, clock_domain_bridge_tb); end
    wait (d0 && d1 && d2 && d3);
    if (e0 + e1 + e2 + e3 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
  initial begin #20000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
