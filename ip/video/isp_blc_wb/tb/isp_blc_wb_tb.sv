// ***************
// Filename: isp_blc_wb_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_blc_wb. Frames in all four
//   CFA patterns with random offsets and gains (including clipping gains
//   and offsets above the pixel value), all four bypass combinations,
//   random input gaps and output back-pressure. Settings are changed in the
//   middle of each frame; the block must keep the values sampled at the
//   frame start. Every output pixel, tuser and tlast is checked against a
//   model. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_blc_wb_tb;
  localparam int PW = 10, MAXP = 4096;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic [1:0] cfa; logic blc_by, wb_by; logic [4*PW-1:0] blc; logic [11:0] gr, gg, gb;
  logic [PW-1:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_blc_wb #(.PW(PW)) dut (.clk, .rst_n, .cfa_i(cfa), .blc_bypass_i(blc_by), .wb_bypass_i(wb_by), .blc_i(blc),
    .gain_r_i(gr), .gain_g_i(gg), .gain_b_i(gb),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int W, H, gap_pct, bp_pct, nout;
  logic [PW-1:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel %0d (%0d,%0d) = %0d exp %0d", nout, nout % W, nout / W, md, exp_px[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  task automatic frame(input int w, input int h, input logic [1:0] p, input bit bb, input bit wbb);
    logic [PW-1:0] off [4]; logic [11:0] g3 [3];
    W = w; H = h; nout = 0;
    cfa = p; blc_by = bb; wb_by = wbb;
    for (int c = 0; c < 4; c++) begin off[c] = $urandom_range(120); blc[c*PW +: PW] = off[c]; end
    g3[0] = $urandom_range(1200); g3[1] = $urandom_range(600); g3[2] = 256 + $urandom_range(3000);
    gr = g3[0]; gg = g3[1]; gb = g3[2];
    for (int i = 0; i < w * h; i++) begin
      int x, y, c, col, v;
      x = i % w; y = i / w; img[i] = (i % 17 == 0) ? 10'd1023 : $urandom_range(1023);
      c = {y[0] ^ p[1], x[0] ^ p[0]};
      col = (c == 0) ? 0 : (c == 3) ? 2 : 1;
      v = bb ? img[i] : ((img[i] > off[c]) ? img[i] - off[c] : 0);
      if (!wbb) begin v = (v * g3[col] + 128) >> 8; if (v > 1023) v = 1023; end
      exp_px[i] = v;
    end
    for (int i = 0; i < w * h; i++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[i]; su <= (i == 0); sl <= (i % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (i == w * h / 2) begin                 // mid-frame changes must not take effect
        cfa <= ~p; blc_by <= ~bb; wb_by <= ~wbb;
      end
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("frame %0dx%0d: %0d pixels out", w, h, nout));
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("isp_blc_wb_tb.vcd"); $dumpvars(0, isp_blc_wb_tb); end
    sv = 0; su = 0; sl = 0; sd = 0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    for (int k = 0; k < 16; k++) begin
      gap_pct = (k % 3) * 20; bp_pct = (k % 4) * 15;
      frame(6 + 2 * k, 3 + k % 5, k[1:0], k[2], k[3]);
    end
    $display("16 frames, all CFA patterns and bypass combinations");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
