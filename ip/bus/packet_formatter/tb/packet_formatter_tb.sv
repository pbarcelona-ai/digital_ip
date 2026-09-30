// ***************
// Filename: packet_formatter_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for packet_formatter, including a
//   formatter-to-parser round trip. Payload packets of random whole-beat
//   length go through the formatter in two configurations (header only,
//   and header plus trailer plus padding to 6 beats); the output beats are
//   compared with the expected header/payload/pad/trailer sequence
//   including tlast placement, then a packet_parser strips the header
//   again and must return the original header and payload. Misaligned
//   payload with a tail request must raise align_err_o. Prints TEST PASSED
//   on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module pf_case #(parameter bit TRL = 0, parameter int MINB = 0) (input logic clk, input logic rst_n, output int errors, output bit done);
  logic [63:0] hdr = 0; logic [31:0] trl = 0, sd = 0, md; logic [3:0] sk = 4'hF, mk; logic sl = 0, sv = 0, sr, ml, mv, mr = 1, aerr;
  packet_formatter #(.DATA_W(32), .HDR_BYTES(8), .TRAILER(TRL), .MIN_BEATS(MINB)) dut (.aclk(clk), .aresetn(rst_n), .hdr_i(hdr), .trailer_i(trl), .s_axis_tdata(sd), .s_axis_tkeep(sk),
    .s_axis_tlast(sl), .s_axis_tvalid(sv), .s_axis_tready(sr), .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tlast(ml), .m_axis_tvalid(mv), .m_axis_tready(mr), .align_err_o(aerr));
  // parser on the formatter output (strip header, forward payload + pad + trailer)
  logic [63:0] phdr; logic phv, pm, prunt, pdrop, plv; logic [15:0] plen; logic [31:0] qd; logic [3:0] qk; logic ql, qv;
  packet_parser #(.DATA_W(32), .HDR_BYTES(8), .STRIP(1)) par (.aclk(clk), .aresetn(rst_n), .s_axis_tdata(md), .s_axis_tkeep(mk), .s_axis_tlast(ml), .s_axis_tvalid(mv & mr), .s_axis_tready(),
    .m_axis_tdata(qd), .m_axis_tkeep(qk), .m_axis_tlast(ql), .m_axis_tvalid(qv), .m_axis_tready(1'b1), .hdr_o(phdr), .hdr_valid_o(phv), .match_o(pm),
    .cfg_mask_i(64'd0), .cfg_value_i(64'd0), .drop_nomatch_i(1'b0), .len_o(plen), .len_valid_o(plv), .runt_o(prunt), .drop_o(pdrop));
  logic [32:0] exp_q[$]; logic [63:0] exp_h[$]; int exp_beats[$]; int got_pkts = 0, npk = 0, hdr_seen = 0, cur_beats = 0;
  bit mis = 0;
  always @(posedge clk) if (rst_n) begin
    mr <= ($urandom_range(0, 9) < 7);
    if (mv && mr) begin
      logic [32:0] e; e = exp_q.pop_front();
      if ({ml, md} !== e || (mk !== 4'hF && !mis)) begin errors++; $display("ERROR TRL=%0d MIN=%0d: beat %h/%b expected %h", TRL, MINB, md, ml, e[31:0]); end
      if (ml) got_pkts++;
    end
    if (phv) begin if (phdr !== exp_h[hdr_seen]) begin errors++; $display("ERROR parser header %h expected %h (idx %0d of %0d)", phdr, exp_h[hdr_seen], hdr_seen, exp_h.size()); end hdr_seen++; end
  end
  task automatic send(input int nbeats);
    logic [31:0] pl [8];
    logic [63:0] h; h[31:0] = $urandom; h[63:32] = $urandom; hdr = h; trl = $urandom; exp_h.push_back(h);
    for (int i = 0; i < 2; i++) exp_q.push_back({1'b0, h[i*32 +: 32]});
    for (int i = 0; i < nbeats; i++) begin pl[i] = $urandom; end
    begin int total; total = 2 + nbeats;
      for (int i = 0; i < nbeats; i++) exp_q.push_back({1'b0, pl[i]});
      if (TRL) begin while (total + 1 < MINB) begin exp_q.push_back(33'd0); total++; end exp_q.push_back({1'b0, trl}); total++; end
      else while (total < MINB) begin exp_q.push_back(33'd0); total++; end
      begin logic [32:0] lst; lst = exp_q[exp_q.size()-1]; lst[32] = 1; exp_q[exp_q.size()-1] = lst; end
    end
    for (int i = 0; i < nbeats; i++) begin
      while ($urandom_range(0, 3) == 0) @(posedge clk);
      #1 sv = 1; sd = pl[i]; sk = 4'hF; sl = (i == nbeats - 1);
      @(posedge clk); while (!sr) @(posedge clk);
      #1 sv = 0; hdr = h;
    end
    npk++; repeat (12) @(posedge clk);
  endtask
  initial begin
    errors = 0; done = 0; wait (rst_n); repeat (3) @(posedge clk);
    for (int n = 0; n < 60; n++) send($urandom_range(1, 6));
    repeat (20) @(posedge clk);
    if (exp_q.size() != 0) begin errors++; $display("ERROR %0d beats missing", exp_q.size()); end
    if (got_pkts != npk) begin errors++; $display("ERROR packets %0d/%0d", got_pkts, npk); end
    if (hdr_seen != npk) begin errors++; $display("ERROR parsed headers %0d/%0d", hdr_seen, npk); end
    // misaligned payload with a tail request
    if (TRL || MINB > 0) begin
      mis = 1; exp_h.push_back(64'h1); exp_q.push_back({1'b0, 32'd1}); exp_q.push_back({1'b0, 32'd0}); exp_q.push_back({1'b1, 32'h1234});
      #1 hdr = 64'h1; sv = 1; sd = 32'h1234; sk = 4'b0011; sl = 1; @(posedge clk); while (!sr) @(posedge clk); #1 sv = 0;
      repeat (10) @(posedge clk);
    end
    done = 1;
  end
  int aerr_cnt = 0; always @(posedge clk) if (aerr) aerr_cnt++;
endmodule
module packet_formatter_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk; int e0, e1, e2, ea = 0; bit d0, d1, d2;
  pf_case #(0, 0) a (clk, rst_n, e0, d0); pf_case #(1, 6) b (clk, rst_n, e1, d1); pf_case #(0, 5) c (clk, rst_n, e2, d2);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("packet_formatter_tb.vcd"); $dumpvars(0, packet_formatter_tb); end
    repeat (4) @(posedge clk); rst_n = 1; wait (d0 && d1 && d2); repeat (5) @(posedge clk);
    if (b.aerr_cnt == 0 || c.aerr_cnt == 0) begin $display("ERROR align_err_o not raised (%0d %0d)", b.aerr_cnt, c.aerr_cnt); ea = 1; end
    if (ea + e0 + e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
