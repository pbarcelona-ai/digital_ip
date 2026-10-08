// ***************
// Filename: isp_gamma_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_gamma. Checks the power-up
//   linear table, then loads an sRGB-like curve (x^(1/2.2)) and an inverted
//   curve through the write port, and runs bypass (changed mid-frame, must
//   only apply at the next frame), with random input gaps and output
//   back-pressure. Every component, tuser and tlast is checked. Prints
//   TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_gamma_tb;
  localparam int IW = 10, OW = 8, MAXP = 2048;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic by, we; logic [IW-1:0] wa; logic [OW-1:0] wd;
  logic [3*IW-1:0] sd; logic [3*OW-1:0] md; logic sl, su, sv, sr, ml, mu, mv, mr;
  isp_gamma #(.IN_W(IW), .OUT_W(OW)) dut (.clk, .rst_n, .bypass_i(by), .lut_we_i(we), .lut_addr_i(wa), .lut_data_i(wd),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));

  int W, gap_pct, bp_pct, nout;
  logic [OW-1:0] lut [1 << IW];
  logic [3*IW-1:0] img [MAXP]; logic [3*OW-1:0] exp_px [MAXP];
  always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
  always @(posedge clk) if (rst_n && mv && mr) begin
    check(md == exp_px[nout], $sformatf("pixel %0d = %h exp %h", nout, md, exp_px[nout]));
    check(mu == (nout == 0) && ml == (nout % W == W - 1), $sformatf("tuser/tlast at pixel %0d", nout));
    nout++;
  end

  task automatic load(input int curve);
    for (int a = 0; a < (1 << IW); a++) begin
      lut[a] = (curve == 1) ? OW'($rtoi(255.0 * ((a / 1023.0) ** (1.0 / 2.2)) + 0.5)) : OW'(255 - (a >> 2));
      @(posedge clk); we <= 1; wa <= a; wd <= lut[a];
    end
    @(posedge clk); we <= 0;
  endtask

  task automatic frame(input int w, input int h, input bit bypass);
    W = w; nout = 0; by = bypass;
    for (int n = 0; n < w * h; n++) begin
      img[n] = {IW'($urandom_range(1023)), IW'($urandom_range(1023)), IW'(n % 1024)};
      for (int k = 0; k < 3; k++) exp_px[n][k*OW +: OW] = bypass ? OW'(img[n][k*IW +: IW] >> 2) : lut[img[n][k*IW +: IW]];
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
    if ($test$plusargs("vcd")) begin $dumpfile("isp_gamma_tb.vcd"); $dumpvars(0, isp_gamma_tb); end
    sv = 0; su = 0; sl = 0; sd = 0; by = 0; we = 0; wa = 0; wd = 0;
    for (int a = 0; a < (1 << IW); a++) lut[a] = a >> 2;                   // power-up contents
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    gap_pct = 10; bp_pct = 20; frame(32, 32, 0);                            // linear: covers every code
    load(1); gap_pct = 20; bp_pct = 30; frame(32, 32, 0);                   // gamma 1/2.2
    load(2); gap_pct = 0;  bp_pct = 50; frame(16, 8, 0);                    // inverted
    gap_pct = 30; bp_pct = 10; frame(16, 8, 1);                             // bypass
    $display("linear (power-up), gamma 2.2, inverted and bypass frames");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
