// ***************
// Filename: isp_stats_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_stats. Streams back-to-back
//   frames of random RGB pixels with random valid / ready handshakes (only
//   accepted pixels may count). A monitor computes each frame's expected
//   component sums, pixel count and clipped-pixel count; every frame_done
//   pulse is checked against the next completed frame, the last one being
//   reported through flush_i. Prints TEST PASSED on success.
//   The test tasks are in tests/isp_stats_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_stats_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  logic [7:0] thr;
  logic flush;
  logic [23:0] d;
  logic u, v, r;
  logic [39:0] sr_, sg, sb;
  logic [31:0] np, nc, nf;
  logic done;
  isp_stats #(.CW(8)) dut (
    .clk,
    .rst_n,
    .sat_thr_i(thr),
    .flush_i(flush),
    .tdata(d),
    .tuser(u),
    .tvalid(v),
    .tready(r),
    .sum_r_o(sr_),
    .sum_g_o(sg),
    .sum_b_o(sb),
    .pixels_o(np),
    .clipped_o(nc),
    .frames_o(nf),
    .frame_done_o(done)
  );

  // Expected totals per frame, filled by the monitor from accepted beats
  localparam int NF = 6;
  longint er [NF], eg [NF], eb [NF];
  int ep [NF], ec [NF];
  int cur = -1, ndone = 0;
  always @(posedge clk) if (rst_n && v && r) begin
    if (u) begin
      cur++;
      er[cur] = 0;
      eg[cur] = 0;
      eb[cur] = 0;
      ep[cur] = 0;
      ec[cur] = 0;
    end
    er[cur] += d[7:0];
    eg[cur] += d[15:8];
    eb[cur] += d[23:16];
    ep[cur]++;
    if (d[7:0] >= thr || d[15:8] >= thr || d[23:16] >= thr) ec[cur]++;
  end
  always @(posedge clk) if (rst_n && done) begin
    #1;
    check(sr_ == er[ndone] && sg == eg[ndone] && sb == eb[ndone],
          $sformatf("frame %0d: sums %0d %0d %0d exp %0d %0d %0d", ndone, sr_, sg, sb, er[ndone], eg[ndone], eb[ndone]));
    check(np == ep[ndone] && nc == ec[ndone] && nf == ndone + 1,
          $sformatf("frame %0d: pixels %0d clipped %0d frames %0d, exp %0d %0d %0d", ndone, np, nc, nf, ep[ndone], ec[ndone], ndone + 1));
    ndone++;
  end

  // test tasks: tests/isp_stats_tests.sv
  `include "isp_stats_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("isp_stats_tb.vcd");
      $dumpvars(0, isp_stats_tb);
    end
    v = 0;
    r = 0;
    u = 0;
    d = 0;
    flush = 0;
    thr = 8'd240;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    for (int f = 0; f < NF; f++) begin
      frame(150 + 53 * f);
      repeat ($urandom_range(5)) @(posedge clk);
    end
    @(posedge clk);
    flush <= 1;
    @(posedge clk);
    flush <= 0;
    repeat (4) @(posedge clk);
    check(ndone == NF, $sformatf("%0d frame_done pulses, exp %0d", ndone, NF));
    $display("%0d frames checked (sums, pixel and clip counts, frame counter)", ndone);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
