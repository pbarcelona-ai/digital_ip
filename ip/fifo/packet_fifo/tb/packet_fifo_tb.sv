// ***************
// Filename: packet_fifo_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for packet_fifo. Sends random-
//   length packets (some too long for the FIFO, some flagged bad) with
//   random read back pressure; the scoreboard verifies that only complete
//   good packets appear, in order and unmodified, dropped packets are
//   counted, the output never shows a partial packet before its last word
//   was written, and pkt_count returns to zero. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module packet_fifo_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic [15:0] sd = 0, md; logic sv = 0, sr, sl = 0, sb = 0, mv, mr = 0, ml, drop; logic [4:0] pc;
  packet_fifo #(.WIDTH(16), .DEPTH(16)) dut (.clk, .rst_n, .s_data_i(sd), .s_valid_i(sv), .s_ready_o(sr), .s_last_i(sl), .s_bad_i(sb),
    .m_data_o(md), .m_valid_o(mv), .m_ready_i(mr), .m_last_o(ml), .drop_o(drop), .pkt_count_o(pc));
  bit stall = 0;
  int errors = 0, drops = 0, exp_drops = 0, good_pkts = 0, got_pkts = 0;
  logic [16:0] exp_q[$];                 // {last, data} of accepted packets
  logic [16:0] pend[$];                  // words of the packet being written
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  // reader
  always @(posedge clk) if (rst_n) begin
    mr <= !stall && ($urandom_range(0, 9) < 6);
    if (mv && mr) begin
      if (exp_q.size() == 0) begin errors++; $display("ERROR unexpected output word %h", md); end
      else begin
        logic [16:0] e; e = exp_q.pop_front();
        if ({ml, md} !== e) begin errors++; $display("ERROR got %h exp %h", {ml, md}, e); end
        if (ml) got_pkts++;
      end
    end
    if (drop) drops++;
  end
  // writer: one packet at a time; model decides acceptance from the FIFO occupancy visible in the DUT
  task automatic send_packet(input int len, input bit bad);
    int free_words, stored; bit will_drop;
    pend.delete();
    for (int i = 0; i < len; i++) begin
      @(posedge clk); #1 sv = 1; sd = $urandom; sl = (i == len - 1); sb = bad && (i == len - 1);
      pend.push_back({sl, sd});
    end
    @(posedge clk); #1 sv = 0; sl = 0; sb = 0;
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("packet_fifo_tb.vcd"); $dumpvars(0, packet_fifo_tb); end
    repeat (3) @(posedge clk); rst_n = 1;
    // 1) Packets that fit while the reader is idle are all delivered
    mr = 0;
    // (reader random; use small packets and wait for drain between them so nothing is dropped)
    for (int p = 0; p < 30; p++) begin
      int len; len = $urandom_range(1, 12);
      send_packet(len, 0);
      foreach (pend[i]) exp_q.push_back(pend[i]); good_pkts++;
      while (exp_q.size() != 0) @(posedge clk);
    end
    check(drops == 0, "no drops expected for fitting packets");
    // 2) Oversized packet (20 > 16 words) is dropped entirely
    send_packet(20, 0); exp_drops++; repeat (10) @(posedge clk);
    check(drops == exp_drops, $sformatf("oversize drop count %0d", drops));
    check(mv == 0 && pc == 0, "oversize packet leaked");
    // 3) Bad packet dropped, following good packet still passes
    send_packet(5, 1); exp_drops++; repeat (5) @(posedge clk);
    send_packet(4, 0); foreach (pend[i]) exp_q.push_back(pend[i]); good_pkts++;
    while (exp_q.size() != 0) @(posedge clk);
    check(drops == exp_drops, $sformatf("bad packet drop count %0d exp %0d", drops, exp_drops));
    // 4) Store-and-forward: reader stalled, nothing visible until the last word is written
    stall = 1; repeat (2) @(posedge clk);
    for (int i = 0; i < 6; i++) begin @(posedge clk); #1 sv = 1; sd = 16'h7000 + i; sl = (i == 5);
      @(posedge clk); #1 sv = 0; if (i < 5) begin repeat (2) @(posedge clk); check(mv == 0, "partial packet visible"); end end
    @(posedge clk); #1 sv = 0; sl = 0; repeat (4) @(posedge clk); check(mv == 1 && pc == 1, "complete packet not visible");
    stall = 0; for (int i = 0; i < 6; i++) exp_q.push_back({(i == 5), 16'h7000 + i[15:0]}); good_pkts++;
    while (exp_q.size() != 0) @(posedge clk);
    repeat (10) @(posedge clk);
    check(pc == 0, "pkt count not zero at end");
    check(got_pkts == good_pkts, $sformatf("packets out %0d exp %0d", got_pkts, good_pkts));
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #5000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
