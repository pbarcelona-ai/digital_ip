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
//   The test tasks are in tests/isp_ccm_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_ccm_tb;
  localparam int PW = 10, MAXP = 2048;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  logic by;
  logic [9*16-1:0] coef;
  logic [3*16-1:0] off;
  axis_if #(.DATA_W((3*PW)), .USER_W(1)) m_axis ();
  axis_if #(.DATA_W((3*PW)), .USER_W(1)) s_axis ();
  isp_ccm #(.PW(PW)) dut (
    .clk,
    .rst_n,
    .bypass_i(by),
    .coef_i(coef),
    .off_i(off),
    .s_axis(s_axis),
    .m_axis(m_axis)
  );

  int W, gap_pct, bp_pct, nout, nclip;
  logic [3*PW-1:0] img [MAXP], exp_px [MAXP];
  always @(posedge clk) m_axis.tready <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && m_axis.tvalid && m_axis.tready) begin
    check(m_axis.tdata == exp_px[nout], $sformatf("pixel %0d = %h exp %h (in %h)", nout, m_axis.tdata, exp_px[nout], img[nout]));
    check(m_axis.tuser == (nout == 0) && m_axis.tlast == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  // test tasks: tests/isp_ccm_tests.sv
  `include "isp_ccm_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("isp_ccm_tb.vcd");
      $dumpvars(0, isp_ccm_tb);
    end
    s_axis.tvalid = 0;
    s_axis.tuser = 0;
    s_axis.tlast = 0;
    s_axis.tdata = 0;
    by = 0;
    coef = '0;
    off = '0;
    nclip = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    gap_pct = 0;
    bp_pct = 0;
    frame(16, 8, 0, 0);
    gap_pct = 20;
    bp_pct = 30;
    frame(16, 8, 1, 0);
    gap_pct = 30;
    bp_pct = 30;
    frame(20, 10, 2, 0);
    gap_pct = 10;
    bp_pct = 40;
    frame(20, 10, 2, 1);
    gap_pct = 10;
    bp_pct = 10;
    frame(12, 6, 2, 0);
    check(nclip > 0, "the random matrices never exercised clamping");
    $display("identity, sensor, random and bypass frames; %0d clamped components", nclip);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
