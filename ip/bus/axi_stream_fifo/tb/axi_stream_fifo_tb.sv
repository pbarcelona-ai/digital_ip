// ***************
// Filename: axi_stream_fifo_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for axi_stream_fifo. Random packets
//   with random tkeep/tuser and random stalls on both sides; every beat,
//   packet boundary and sideband must arrive in order, the FIFO must reach
//   full (backpressure) and drain to level 0. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module axi_stream_fifo_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic [31:0] sd = 0, md; logic [3:0] sk = 0, mk; logic sl = 0, mlast; logic [1:0] su = 0, mu; logic sv = 0, sr, mv, mr = 0; logic [6:0] lvl;
  axi_stream_fifo #(.DATA_W(32), .USER_W(2), .DEPTH(32)) dut (.aclk(clk), .aresetn(rst_n), .s_axis_tdata(sd), .s_axis_tkeep(sk), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tlast(mlast), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr), .level_o(lvl));
  int errors = 0, sent = 0, got = 0, full_seen = 0; localparam int N = 3000; logic [38:0] q[$]; int plen = 0;
  always @(posedge clk) if (rst_n) begin
    if (sv && sr) begin q.push_back({su, sl, sk, sd}); sent++; end
    if (!sr) full_seen++;
    if (mv && mr) begin
      logic [38:0] e; e = q.pop_front();
      if ({mu, mlast, mk, md} !== e) begin errors++; $display("ERROR beat %0d got %h exp %h", got, {mu, mlast, mk, md}, e); end
      got++;
    end
    if (!sv || sr) begin
      if (sent < N && $urandom_range(0, 9) < (sent < 1000 ? 9 : 4)) begin
        if (plen == 0) plen = $urandom_range(1, 10);
        sv <= 1; sd <= $urandom; sk <= (plen == 1) ? $urandom : 4'hF; sl <= (plen == 1); su <= $urandom; plen--;
      end else sv <= 0;
    end
    mr <= ($urandom_range(0, 9) < (sent < 1000 ? 3 : 8));
  end
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("axi_stream_fifo_tb.vcd"); $dumpvars(0, axi_stream_fifo_tb); end
    repeat (4) @(posedge clk); rst_n = 1;
    wait (got >= N); repeat (10) @(posedge clk);
    if (sent != got) begin errors++; $display("ERROR sent %0d got %0d", sent, got); end
    if (full_seen == 0) begin errors++; $display("ERROR never backpressured"); end
    if (lvl != 0) begin errors++; $display("ERROR level %0d after drain", lvl); end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #20000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
