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
//   The test tasks are in tests/isp_blc_wb_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_blc_wb_tb;
  localparam int PW = 10, MAXP = 4096;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  logic [1:0] cfa;
  logic blc_by, wb_by;
  logic [4*PW-1:0] blc;
  logic [11:0] gr, gg, gb;
  logic [PW-1:0] sd, md;
  logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_blc_wb #(.PW(PW)) dut (
    .clk,
    .rst_n,
    .cfa_i(cfa),
    .blc_bypass_i(blc_by),
    .wb_bypass_i(wb_by),
    .blc_i(blc),
    .gain_r_i(gr),
    .gain_g_i(gg),
    .gain_b_i(gb),
    .s_axis_tdata(sd),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .m_axis_tdata(md),
    .m_axis_tlast(ml),
    .m_axis_tuser(mu),
    .m_axis_tvalid(mv),
    .m_axis_tready(mr)
  );

  int W, H, gap_pct, bp_pct, nout;
  logic [PW-1:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel %0d (%0d,%0d) = %0d exp %0d", nout, nout % W, nout / W, md, exp_px[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  // test tasks: tests/isp_blc_wb_tests.sv
  `include "isp_blc_wb_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("isp_blc_wb_tb.vcd");
      $dumpvars(0, isp_blc_wb_tb);
    end
    sv = 0;
    su = 0;
    sl = 0;
    sd = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    for (int k = 0; k < 16; k++) begin
      gap_pct = (k % 3) * 20;
      bp_pct = (k % 4) * 15;
      frame(6 + 2 * k, 3 + k % 5, k[1:0], k[2], k[3]);
    end
    $display("16 frames, all CFA patterns and bypass combinations");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
