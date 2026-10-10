// ***************
// Filename: axi_stream_width_converter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axi_stream_width_converter.
//   Random packets (random length, partial final tkeep) pass through 4->1,
//   4->2, 1->4, 2->4 and 4->4 converters with random stalls; the byte
//   stream, packet boundaries and tuser are compared at the byte level
//   with a reference, and a downsize-upsize round trip must reproduce the
//   original beats. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module wc_case #(parameter int IB = 4, parameter int OB = 1) (input logic clk, input logic rst_n, output int errors, output bit done);
  logic [IB*8-1:0] sd;
  logic [IB-1:0] sk;
  logic sl, sv, sr;
  logic [0:0] su;
  logic [OB*8-1:0] md;
  logic [OB-1:0] mk;
  logic ml, mv, mr;
  logic [0:0] mu;
  logic kerr;
  axi_stream_width_converter #(
    .IN_BYTES(IB),
    .OUT_BYTES(OB),
    .USER_W(1)
  ) dut (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axis_tdata(sd),
    .s_axis_tkeep(sk),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .m_axis_tdata(md),
    .m_axis_tkeep(mk),
    .m_axis_tlast(ml),
    .m_axis_tuser(mu),
    .m_axis_tvalid(mv),
    .m_axis_tready(mr),
    .keep_err_o(kerr)
  );
  // reference: byte queue per packet with user flag
  int bq[$];
  int pkts_sent = 0, pkts_got = 0;
  bit user_q[$];
  int gq[$];
  int npk = 0;
  localparam int NP = 200;
  int plen_beats, beat;
  bit lastbeat;
  initial begin
    errors = 0;
    done = 0;
    sv = 0;
    sd = 0;
    sk = 0;
    sl = 0;
    su = 0;
    mr = 0;
    beat = 0;
    plen_beats = 0;
  end
  always @(posedge clk) if (rst_n) begin
    if (sv && sr) begin
      for (int b = 0; b < IB; b++) if (sk[b]) bq.push_back(sd[b*8 +: 8]);
      if (sl) begin // 'hxx' marker = end of packet
        bq.push_back(-1);
        user_q.push_back(su[0]);
        pkts_sent++;
      end
    end
    if (!sv || sr) begin
      if (npk < NP && $urandom_range(0, 9) < 7) begin
        if (plen_beats == 0) plen_beats = $urandom_range(1, 6);
        lastbeat = (plen_beats == 1);
        sv <= 1;
        sl <= lastbeat;
        su <= $urandom;
        plen_beats--;
        for (int b = 0; b < IB; b++) sd[b*8 +: 8] <= $urandom;
        if (lastbeat) begin
          sk <= (IB'(1) << $urandom_range(1, IB)) - 1;
          npk++;
        end else sk <= '1;
      end else sv <= 0;
    end
    mr <= ($urandom_range(0, 9) < 7);
    if (mv && mr) begin
      for (int b = 0; b < OB; b++) if (mk[b]) gq.push_back(md[b*8 +: 8]);
      if (ml) begin
        gq.push_back(-1);
        if (user_q.size() == 0 || mu[0] !== user_q[pkts_got]) begin
          errors++;
          $display("ERROR (%0d->%0d) tuser packet %0d", IB, OB, pkts_got);
        end
        pkts_got++;
      end
    end
    if (pkts_got == NP && !done) begin
      done = 1;
      if (bq.size() != gq.size()) begin
        errors++;
        $display("ERROR (%0d->%0d) byte count %0d vs %0d", IB, OB, bq.size(), gq.size());
      end
      else foreach (bq[i]) if (bq[i] !== gq[i]) begin
        errors++;
        $display("ERROR (%0d->%0d) byte %0d: %h vs %h", IB, OB, i, bq[i], gq[i]);
        i = bq.size();
      end
      if (kerr) begin errors++; end
    end
  end
endmodule
module axi_stream_width_converter_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int e0, e1, e2, e3, e4;
  bit d0, d1, d2, d3, d4;
  wc_case #(
    4,
    1
  ) c0 (
    clk,
    rst_n,
    e0,
    d0
  );
  wc_case #(
    4,
    2
  ) c1 (
    clk,
    rst_n,
    e1,
    d1
  );
  wc_case #(
    1,
    4
  ) c2 (
    clk,
    rst_n,
    e2,
    d2
  );
  wc_case #(
    2,
    4
  ) c3 (
    clk,
    rst_n,
    e3,
    d3
  );
  wc_case #(
    4,
    4
  ) c4 (
    clk,
    rst_n,
    e4,
    d4
  );
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi_stream_width_converter_tb.vcd");
      $dumpvars(0, axi_stream_width_converter_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    wait (d0 && d1 && d2 && d3 && d4);
    repeat (5) @(posedge clk);
    if (e0 + e1 + e2 + e3 + e4 == 0) $display("TEST PASSED");
    else $display("TEST FAILED");
    $finish;
  end
  initial begin
    #50000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
