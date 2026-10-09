// ***************
// Filename: packet_parser_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for packet_parser. Random packets
//   (1..8 beats of 32 bits, random partial tkeep on the last beat, some
//   runts shorter than the 8 byte header) with random input valid and
//   output ready gaps; checks the captured header, header stripping
//   (STRIP=1) and forwarding (STRIP=0), byte-exact payload forwarding,
//   length reporting, runt flagging, and filtering by mask/value with
//   dropped packets never reaching the output. Prints TEST PASSED on
//   success.
//   The test tasks are in tests/packet_parser_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module pp_case #(parameter bit STRIP = 1) (input logic clk, input logic rst_n, output int errors, output bit done);
  localparam int HB = 8;
  logic [31:0] sd = 0, md; logic [3:0] sk = 0, mk; logic sl = 0, sv = 0, sr, ml, mv, mr = 1;
  logic [HB*8-1:0] hdr, mask, value; logic hv, match, runt, drop, lv, dn = 1; logic [15:0] len;
  packet_parser #(.DATA_W(32), .HDR_BYTES(HB), .STRIP(STRIP)) dut (.aclk(clk), .aresetn(rst_n), .s_axis_tdata(sd), .s_axis_tkeep(sk), .s_axis_tlast(sl), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tkeep(mk), .m_axis_tlast(ml), .m_axis_tvalid(mv), .m_axis_tready(mr), .hdr_o(hdr), .hdr_valid_o(hv), .match_o(match),
    .cfg_mask_i(mask), .cfg_value_i(value), .drop_nomatch_i(dn), .len_o(len), .len_valid_o(lv), .runt_o(runt), .drop_o(drop));
  // reference
  byte pk[$];                                    // bytes of the packet being sent
  int hdr_q_n = 0, exp_pkts = 0;
  logic [HB*8-1:0] exp_hdr[$]; int exp_len[$]; bit exp_runt[$], exp_drop[$];
  byte exp_out[$]; int exp_pkt_ends[$]; byte got_out[$]; int got_ends[$];
  int hdrs = 0, lens = 0, runts = 0, drops = 0, ei_h = 0, ei_l = 0;
  always @(posedge clk) begin
    if (hv) begin if (hdrs < exp_hdr.size() && hdr === exp_hdr[hdrs]) begin end else begin errors++; $display("ERROR header %h", hdr); end hdrs++; end
    if (lv) begin if (lens < exp_len.size() && len == exp_len[lens]) begin end else begin errors++; $display("ERROR len %0d", len); end lens++; end
    if (runt) runts++; if (drop) drops++;
    if (mv && mr) begin
      for (int b = 0; b < 4; b++) if (mk[b]) got_out.push_back(md[b*8 +: 8]);
      if (ml) got_ends.push_back(got_out.size());
    end
  end
  always @(posedge clk) if (rst_n) mr <= ($urandom_range(0, 9) < 7);
  // test tasks: tests/packet_parser_tests.sv
  `include "packet_parser_tests.sv"
  initial begin
    errors = 0; done = 0;
    mask = 64'hFFFF_0000_0000_0000; value = 64'h0000_0000_0000_3CA5; mask = 64'h0000_0000_0000_FFFF;     // low 16 bits = bytes 0,1 (little endian)
    wait (rst_n); repeat (3) @(posedge clk);
    for (int n = 0; n < 200; n++) begin
      int len_; len_ = ($urandom_range(0, 9) == 0) ? $urandom_range(1, HB - 1) : $urandom_range(HB, 36);
      // STRIP=0 with a non-matching header still forwards the header beats: adapt expectation in send()
      send(len_, $urandom_range(0, 3) != 0);
    end
    repeat (40) @(posedge clk);
    if (got_out.size() != exp_out.size()) begin errors++; $display("ERROR STRIP=%0d output bytes %0d expected %0d", STRIP, got_out.size(), exp_out.size()); end
    else foreach (exp_out[i]) if (got_out[i] !== exp_out[i]) begin errors++; $display("ERROR STRIP=%0d out byte %0d %h vs %h", STRIP, i, got_out[i], exp_out[i]); i = exp_out.size(); end
    if (got_ends.size() != exp_pkt_ends.size()) begin errors++; $display("ERROR STRIP=%0d packets out %0d expected %0d", STRIP, got_ends.size(), exp_pkt_ends.size()); end
    if (runts != exp_runt.size()) begin errors++; $display("ERROR runts %0d expected %0d", runts, exp_runt.size()); end
    if (drops != exp_drop.size()) begin errors++; $display("ERROR drops %0d expected %0d", drops, exp_drop.size()); end
    if (hdrs != exp_hdr.size() || lens != exp_len.size()) begin errors++; $display("ERROR hdrs %0d/%0d lens %0d/%0d", hdrs, exp_hdr.size(), lens, exp_len.size()); end
    done = 1;
  end
endmodule
module packet_parser_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk; int e0, e1; bit d0, d1;
  pp_case #(1) a (clk, rst_n, e0, d0); pp_case #(0) b (clk, rst_n, e1, d1);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("packet_parser_tb.vcd"); $dumpvars(0, packet_parser_tb); end
    repeat (4) @(posedge clk); rst_n = 1; wait (d0 && d1); repeat (5) @(posedge clk);
    if (e0 + e1 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
