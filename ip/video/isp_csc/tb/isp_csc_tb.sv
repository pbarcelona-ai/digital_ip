// ***************
// Filename: isp_csc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_csc. Converts the eight
//   colour-bar colours plus random pixels with BT.601 and BT.709 and checks
//   against the integer model and against the textbook limited-range values
//   (black Y=16, white Y=235, grey Cb=Cr=128, within 1 LSB), then bypass,
//   with settings changed mid-frame (must only apply at the next frame),
//   random input gaps and output back-pressure. Prints TEST PASSED on
//   success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_csc_tb;
  localparam int MAXP = 2048;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic by, m709; logic [23:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_csc dut (.clk, .rst_n, .bypass_i(by), .bt709_i(m709),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int W, gap_pct, bp_pct, nout;
  logic [23:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel %0d = %h exp %h (in %h)", nout, md, exp_px[nout], img[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  function automatic int clamp8(input int v); return (v < 0) ? 0 : (v > 255) ? 255 : v; endfunction
  function automatic logic [23:0] model(input logic [23:0] p, input bit bt709);
    int r, g, b, y, cb, cr;
    r = p[7:0]; g = p[15:8]; b = p[23:16];
    if (bt709) begin
      y = 47*r + 157*g + 16*b + 128; cb = -26*r - 86*g + 112*b + 128; cr = 112*r - 102*g - 10*b + 128;
    end else begin
      y = 66*r + 129*g + 25*b + 128; cb = -38*r - 74*g + 112*b + 128; cr = 112*r - 94*g - 18*b + 128;
    end
    return {8'(clamp8(128 + (cb >>> 8))), 8'(clamp8(16 + (y >>> 8))), 8'(clamp8(128 + (cr >>> 8)))};
  endfunction

  task automatic frame(input int w, input int h, input bit bt709, input bit bypass);
    W = w; nout = 0; m709 = bt709; by = bypass;
    for (int n = 0; n < w * h; n++) begin
      if (n < 8) img[n] = {{8{n[2]}}, {8{n[1]}}, {8{n[0]}}};       // colour bar colours
      else img[n] = {8'($urandom_range(255)), 8'($urandom_range(255)), 8'($urandom_range(255))};
      exp_px[n] = bypass ? img[n] : model(img[n], bt709);
    end
    for (int n = 0; n < w * h; n++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[n]; su <= (n == 0); sl <= (n % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (n == w * h / 2) begin by <= ~bypass; m709 <= ~bt709; end
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("%0d pixels out of %0d", nout, w * h));
  endtask

  initial begin
    logic [23:0] k, wh, gy;
    if ($test$plusargs("vcd")) begin $dumpfile("isp_csc_tb.vcd"); $dumpvars(0, isp_csc_tb); end
    // Textbook anchors for both matrices: black, white, mid grey
    for (int m = 0; m < 2; m++) begin
      k = model(24'h000000, m); wh = model(24'hFFFFFF, m); gy = model(24'h808080, m);
      check(k == 24'h801080, $sformatf("matrix %0d: black -> %h", m, k));
      check(wh[15:8] >= 234 && wh[15:8] <= 236 && wh[7:0] >= 127 && wh[7:0] <= 129 && wh[23:16] >= 127 && wh[23:16] <= 129,
            $sformatf("matrix %0d: white -> %h", m, wh));
      check(gy[7:0] >= 127 && gy[7:0] <= 129 && gy[23:16] >= 127 && gy[23:16] <= 129, $sformatf("matrix %0d: grey -> %h", m, gy));
    end
    sv = 0; su = 0; sl = 0; sd = 0; by = 0; m709 = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    gap_pct = 0;  bp_pct = 0;  frame(16, 8, 0, 0);
    gap_pct = 20; bp_pct = 30; frame(16, 8, 1, 0);
    gap_pct = 30; bp_pct = 30; frame(20, 6, 1, 1);
    gap_pct = 10; bp_pct = 40; frame(20, 6, 0, 0);
    $display("BT.601, BT.709 and bypass frames");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
