// ***************
// Filename: nco_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for nco. Verifies the output
//   frequency from the carry pulse count for several tuning words against
//   f_out = tuning * f_clk / 2^W, the accumulator against a reference
//   model, phase offset, load, clock enable gating and the Nyquist flag.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/nco_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module nco_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic ce = 1, ld = 0;
  logic [15:0] tw = 0, off = 0, pl = 0, ph;
  logic co, msb, ny;
  nco #(.PHASE_W(16)) dut (
    .clk,
    .rst_n,
    .ce_i(ce),
    .tuning_i(tw),
    .phase_off_i(off),
    .sync_load_i(ld),
    .phase_load_i(pl),
    .phase_o(ph),
    .carry_o(co),
    .msb_o(msb),
    .nyquist_o(ny)
  );
  int errors = 0;
  int carries;
  logic [15:0] macc = 0, mph = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      macc <= 0;
      mph <= 0;
    end
    else if (ld) begin
      macc <= pl;
      mph <= pl + off;
    end
    else if (ce) begin
      macc <= macc + tw;
      mph <= 16'(macc + tw + off);
    end
    if (co) carries++;
  end
  always @(negedge clk) if (rst_n && ph !== mph) begin
    errors++;
    $display("ERROR phase %h exp %h", ph, mph);
  end
  // test tasks: tests/nco_tests.sv
  `include "nco_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("nco_tb.vcd");
      $dumpvars(0, nco_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    for (int k = 0; k < 3; k++) begin
      int cnt;
      logic [15:0] t;
      t = (k == 0) ? 16'd655 : (k == 1) ? 16'd1311 : 16'd8192;      // 0.01, 0.02, 0.125 of fclk
      @(posedge clk);
      #1 tw = t;
      ld = 1;
      pl = 0;
      @(posedge clk);
      #1 ld = 0;
      carries = 0;
      repeat (65536) @(posedge clk);
      // expected carries = 65536 * t / 65536 = t
      check(carries == t || carries == t - 1 || carries == t + 1, $sformatf("tuning %0d: carries %0d", t, carries));
    end
    // clock enable gating: accumulator frozen
    tw = 16'h1234;
    ld = 1;
    pl = 0;
    @(posedge clk);
    #1 ld = 0;
    ce = 0;
    repeat (10) @(posedge clk);
    #1;
    check(ph == off, "phase moved while ce=0");
    ce = 1;
    off = 16'h4000;
    repeat (5) @(posedge clk);
    // load
    @(posedge clk);
    #1 ld = 1;
    pl = 16'hBEEF;
    @(posedge clk);
    #1 ld = 0;
    // nyquist flag
    tw = 16'h8000;
    #1 check(ny == 1, "nyquist flag");
    tw = 16'h7FFF;
    #1 check(ny == 0, "nyquist flag stuck");
    // msb is a 50% square wave: half period = 2^15/tw clocks
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
