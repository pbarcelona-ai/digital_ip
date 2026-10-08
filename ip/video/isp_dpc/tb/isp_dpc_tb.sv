// ***************
// Filename: isp_dpc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_dpc. Smooth Bayer-like frames
//   with planted hot and dead pixels (isolated interior defects, which must
//   all be corrected, plus defects on the corners, which mirrored borders also correct),
//   two thresholds, bypass on and off (changed mid-frame, must only apply
//   at the next frame), random input gaps and output back-pressure. Every
//   output pixel, tuser, tlast and the number of corrected_o pulses are
//   checked against a mirror-border (reflect-101) model. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_dpc_tb;
  localparam int PW = 10, MAXP = 4096;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic [15:0] W, H; logic by; logic [PW-1:0] thr; logic corr;
  logic [PW-1:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_dpc #(.PW(PW), .MAX_W(64)) dut (.clk, .rst_n, .width_i(W), .height_i(H), .bypass_i(by), .thr_i(thr), .corrected_o(corr),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int gap_pct, bp_pct, nout, ncorr;
  logic [PW-1:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n) begin
    ncorr += corr;
    if (mv && mr) begin
      check(md == exp_px[nout], $sformatf("pixel (%0d,%0d) = %0d exp %0d", nout % W, nout / W, md, exp_px[nout]));
      check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
      nout++;
    end
  end

  function automatic int px(input int x, input int y);
    if (x < 0) x = -x; if (y < 0) y = -y; if (x >= W) x = 2 * (W - 1) - x; if (y >= H) y = 2 * (H - 1) - y;
    return img[y * W + x];
  endfunction

  task automatic frame(input int w, input int h, input int t, input bit bypass);
    int exp_corr, nplant; exp_corr = 0;
    W = w; H = h; thr = t; by = bypass; nout = 0; ncorr = 0;
    for (int i = 0; i < w * h; i++) begin                       // smooth gradient per CFA colour
      int x, y; x = i % w; y = i / w;
      img[i] = 200 + 8 * x + 5 * y + ((x % 2) ? 40 : 0) + ((y % 2) ? 25 : 0) + $urandom_range(6);
    end
    img[0] = 1023; img[w - 1] = 0; img[(h - 1) * w] = 1000; img[w * h - 1] = 3;        // corners
    nplant = 0;                                                                       // isolated interior
    for (int k = 0; 2 + 5 * k < w - 2; k++) begin                                     // defects, 5 apart
      int px_, py_; px_ = 2 + 5 * k; py_ = 2 + (k % 2) * 3;
      if (py_ < h - 2) begin img[py_ * w + px_] = (k % 2) ? 1023 : 0; nplant++; end
    end
    for (int i = 0; i < w * h; i++) begin
      int x, y, mx, mn, c; x = i % w; y = i / w; c = img[i]; mx = 0; mn = 1023;
      for (int dy = -2; dy <= 2; dy += 2) for (int dx = -2; dx <= 2; dx += 2)
        if (!(dx == 0 && dy == 0)) begin
          if (px(x + dx, y + dy) > mx) mx = px(x + dx, y + dy);
          if (px(x + dx, y + dy) < mn) mn = px(x + dx, y + dy);
        end
      exp_px[i] = c;
      if (!bypass && c > mx + t)      begin exp_px[i] = mx; exp_corr++; end
      else if (!bypass && c + t < mn) begin exp_px[i] = mn; exp_corr++; end
    end
    for (int i = 0; i < w * h; i++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[i]; su <= (i == 0); sl <= (i % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (i == w * h / 2) by <= ~bypass;
    end
    sv <= 0;
    repeat (8 * w) @(posedge clk);
    check(nout == w * h, $sformatf("%0dx%0d: %0d pixels out", w, h, nout));
    check(ncorr == exp_corr, $sformatf("%0dx%0d: %0d corrections, exp %0d", w, h, ncorr, exp_corr));
    if (!bypass && t <= 60) check(exp_corr >= nplant, $sformatf("%0dx%0d: only %0d of %0d isolated defects corrected", w, h, exp_corr, nplant));
    $display("frame %0dx%0d thr=%0d bypass=%0b: %0d pixels corrected", w, h, t, bypass, ncorr);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("isp_dpc_tb.vcd"); $dumpvars(0, isp_dpc_tb); end
    sv = 0; su = 0; sl = 0; sd = 0; W = 16; H = 8; thr = 0; by = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    gap_pct = 0;  bp_pct = 0;  frame(16, 10, 60, 0);
    gap_pct = 25; bp_pct = 35; frame(24, 12, 60, 0);
    gap_pct = 10; bp_pct = 10; frame(20, 8, 0, 0);
    gap_pct = 10; bp_pct = 10; frame(20, 8, 60, 1);
    gap_pct = 30; bp_pct = 50; frame(64, 6, 30, 0);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
