// ***************
// Filename: isp_demosaic_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_demosaic. Random RAW frames
//   in all four CFA patterns, bypass on and off, with the pattern and
//   bypass changed mid-frame (must only apply at the next frame), random
//   input gaps and output back-pressure. Every R, G, B value, tuser and
//   tlast is checked against a bilinear mirror-border (reflect-101) model. A second check
//   mosaics a linear RGB ramp and verifies the reconstruction: exact to
//   1 LSB inside the frame, within one ramp step on the edges. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_demosaic_tb;
  localparam int PW = 10, MAXP = 4096;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic [15:0] W, H; logic [1:0] cfa; logic by;
  logic [PW-1:0] sd; logic [3*PW-1:0] md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_demosaic #(.PW(PW), .MAX_W(64)) dut (.clk, .rst_n, .width_i(W), .height_i(H), .cfa_i(cfa), .bypass_i(by),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int gap_pct, bp_pct, nout, max_err, max_err_in; bit ramp;
  logic [PW-1:0] img [MAXP]; logic [3*PW-1:0] exp_px [MAXP]; int truth [MAXP][3];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel (%0d,%0d) = %h exp %h", nout % W, nout / W, md, exp_px[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    if (ramp) for (int k = 0; k < 3; k++) begin
      int d, xx, yy; d = int'(md[k*PW +: PW]) - truth[nout][k]; if (d < 0) d = -d;
      xx = nout % W; yy = nout / W;
      if (xx > 0 && yy > 0 && xx < W - 1 && yy < H - 1) begin if (d > max_err_in) max_err_in = d; end
      else if (d > max_err) max_err = d;
    end
    nout++;
  end

  function automatic int px(input int x, input int y);
    if (x < 0) x = -x; if (y < 0) y = -y; if (x >= W) x = 2 * (W - 1) - x; if (y >= H) y = 2 * (H - 1) - y;
    return img[y * W + x];
  endfunction

  task automatic frame(input int w, input int h, input logic [1:0] p, input bit bypass, input bit is_ramp);
    W = w; H = h; cfa = p; by = bypass; nout = 0; ramp = is_ramp; max_err = 0; max_err_in = 0;
    for (int i = 0; i < w * h; i++) begin
      int x, y, c; x = i % w; y = i / w; c = {y[0] ^ p[1], x[0] ^ p[0]};
      truth[i][0] = 100 + 9 * x + 4 * y; truth[i][1] = 300 + 5 * x + 7 * y; truth[i][2] = 50 + 3 * x + 11 * y;
      if (is_ramp) img[i] = (c == 0) ? truth[i][0] : (c == 3) ? truth[i][2] : truth[i][1];
      else         img[i] = $urandom_range(1023);
    end
    for (int i = 0; i < w * h; i++) begin
      int x, y, c, r, g, b, cr, dg, hz, vt;
      x = i % w; y = i / w; c = {y[0] ^ p[1], x[0] ^ p[0]};
      cr = (px(x, y-1) + px(x, y+1) + px(x-1, y) + px(x+1, y) + 2) >> 2;
      dg = (px(x-1, y-1) + px(x+1, y-1) + px(x-1, y+1) + px(x+1, y+1) + 2) >> 2;
      hz = (px(x-1, y) + px(x+1, y) + 1) >> 1; vt = (px(x, y-1) + px(x, y+1) + 1) >> 1;
      case (c)
        0: begin r = img[i]; g = cr; b = dg; end
        3: begin r = dg; g = cr; b = img[i]; end
        1: begin r = hz; g = img[i]; b = vt; end
        default: begin r = vt; g = img[i]; b = hz; end
      endcase
      if (bypass) begin r = img[i]; g = img[i]; b = img[i]; end
      exp_px[i] = {PW'(b), PW'(g), PW'(r)};
    end
    for (int i = 0; i < w * h; i++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[i]; su <= (i == 0); sl <= (i % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (i == w * h / 2) begin cfa <= ~p; by <= ~bypass; end
    end
    sv <= 0;
    repeat (6 * w) @(posedge clk);
    check(nout == w * h, $sformatf("%0dx%0d: %0d pixels out", w, h, nout));
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("isp_demosaic_tb.vcd"); $dumpvars(0, isp_demosaic_tb); end
    sv = 0; su = 0; sl = 0; sd = 0; W = 16; H = 8; cfa = 0; by = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    for (int k = 0; k < 8; k++) begin
      gap_pct = (k % 3) * 20; bp_pct = (k % 4) * 15;
      frame(8 + 4 * k, 5 + k, k[1:0], k[2], 0);
    end
    $display("8 random frames, all CFA patterns, bypass on/off");
    for (int p = 0; p < 4; p++) begin
      gap_pct = 10; bp_pct = 10; frame(24, 16, p[1:0], 0, 1);
      // Bilinear interpolation of a linear ramp is exact up to rounding inside
      // the frame. On the edge, mirrored neighbours make an average of two
      // copies of one pixel, so the error is at most one step of the ramp
      // (slopes R 9/4, G 5/7, B 3/11 per pixel in x/y; diagonal B at a
      // corner: 3 + 11 = 14).
      check(max_err_in <= 1, $sformatf("CFA %0d: interior ramp error %0d", p, max_err_in));
      check(max_err <= 14, $sformatf("CFA %0d: edge ramp error %0d", p, max_err));
      $display("CFA pattern %0d ramp: max error interior %0d LSB, edge %0d LSB", p, max_err_in, max_err);
    end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
