// ***************
// Filename: isp_ccm_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_ccm. Identity matrix (output
//   must equal input), a typical sensor matrix with negative terms, random
//   matrices and offsets that drive the result below 0 and above full
//   scale (clamping), and bypass, with settings changed mid-frame (bypass
//   must only apply at the next frame), random input gaps and output
//   back-pressure. Every component, tuser and tlast is checked against a
//   model. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_ccm_tb;
  localparam int PW = 10, MAXP = 2048;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic by; logic [9*16-1:0] coef; logic [3*16-1:0] off;
  logic [3*PW-1:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_ccm #(.PW(PW)) dut (.clk, .rst_n, .bypass_i(by), .coef_i(coef), .off_i(off),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int W, gap_pct, bp_pct, nout, nclip;
  logic [3*PW-1:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel %0d = %h exp %h (in %h)", nout, md, exp_px[nout], img[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  task automatic frame(input int w, input int h, input int kind, input bit bypass);
    int m [3][3]; int o [3];
    W = w; nout = 0; by = bypass;
    for (int i = 0; i < 3; i++) begin o[i] = 0; for (int j = 0; j < 3; j++) m[i][j] = (i == j) ? 1024 : 0; end
    if (kind == 1) begin                               // typical sensor CCM
      m[0][0] = 1720; m[0][1] = -520; m[0][2] = -176;
      m[1][0] = -300; m[1][1] = 1580; m[1][2] = -256;
      m[2][0] = -60;  m[2][1] = -610; m[2][2] = 1694;
    end
    if (kind == 2) begin                               // random, with offsets
      for (int i = 0; i < 3; i++) begin o[i] = $urandom_range(400) - 200; for (int j = 0; j < 3; j++) m[i][j] = $urandom_range(6000) - 3000; end
    end
    for (int i = 0; i < 3; i++) begin off[i*16 +: 16] = o[i]; for (int j = 0; j < 3; j++) coef[(3*i + j)*16 +: 16] = m[i][j]; end
    for (int n = 0; n < w * h; n++) begin
      img[n] = {PW'($urandom_range(1023)), PW'($urandom_range(1023)), PW'($urandom_range(1023))};
      for (int i = 0; i < 3; i++) begin
        longint s; int v;
        s = 512; for (int j = 0; j < 3; j++) s += longint'(m[i][j]) * longint'(img[n][j*PW +: PW]);
        v = int'(s >>> 10) + o[i];
        if (v < 0 || v > 1023) nclip++;
        if (v < 0) v = 0; if (v > 1023) v = 1023;
        exp_px[n][i*PW +: PW] = bypass ? img[n][i*PW +: PW] : PW'(v);
      end
    end
    for (int n = 0; n < w * h; n++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[n]; su <= (n == 0); sl <= (n % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (n == w * h / 2) by <= ~bypass;
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("%0d pixels out of %0d", nout, w * h));
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("isp_ccm_tb.vcd"); $dumpvars(0, isp_ccm_tb); end
    sv = 0; su = 0; sl = 0; sd = 0; by = 0; coef = '0; off = '0; nclip = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    gap_pct = 0;  bp_pct = 0;  frame(16, 8, 0, 0);
    gap_pct = 20; bp_pct = 30; frame(16, 8, 1, 0);
    gap_pct = 30; bp_pct = 30; frame(20, 10, 2, 0);
    gap_pct = 10; bp_pct = 40; frame(20, 10, 2, 1);
    gap_pct = 10; bp_pct = 10; frame(12, 6, 2, 0);
    check(nclip > 0, "the random matrices never exercised clamping");
    $display("identity, sensor, random and bypass frames; %0d clamped components", nclip);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
