// ***************
// Filename: pulse_sync_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for pulse_sync. Random pulses
//   across several clock ratios: every accepted pulse must appear exactly
//   once in the destination, pulses issued while busy must raise drop_o
//   and never appear, and busy must eventually clear. Prints TEST PASSED
//   on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module ps_case #(parameter real SP = 10.0, parameter real DP = 27.0) (output int errors);
  logic sclk = 0, dclk = 0, srst = 0, drst = 0, p = 0, busy, drop, po;
  always #(SP/2) sclk = ~sclk;
  always #(DP/2) dclk = ~dclk;
  pulse_sync #(.STAGES(2)) dut (
    .src_clk(sclk),
    .src_rst_n(srst),
    .pulse_i(p),
    .busy_o(busy),
    .drop_o(drop),
    .dst_clk(dclk),
    .dst_rst_n(drst),
    .pulse_o(po)
  );
  int acc = 0, dropped = 0, got = 0, issued = 0;
  always @(posedge dclk) if (po) got++;
  always @(posedge sclk) begin
    if (srst && p && !busy) acc++;
    if (drop) dropped++;
  end
  initial begin
    errors = 0;
    repeat (5) @(posedge sclk);
    srst = 1;
    drst = 1;
    repeat (5) @(posedge sclk);
    repeat (400) begin
      @(posedge sclk);
      #1 p = ($urandom_range(0, 9) < 3);
      if (p) issued++;
    end
    @(posedge sclk);
    #1 p = 0;
    repeat (60) @(posedge sclk);
    if (busy) begin
      errors++;
      $display("ERROR busy stuck");
    end
    if (got != acc) begin
      errors++;
      $display("ERROR accepted %0d got %0d", acc, got);
    end
    if (acc + dropped != issued) begin
      errors++;
      $display("ERROR acc %0d + drop %0d != issued %0d", acc, dropped, issued);
    end
    if (dropped == 0) begin
      errors++;
      $display("ERROR no drop exercised");
    end
  end
endmodule
module pulse_sync_tb;
  int e1, e2, e3;
  ps_case #(.SP(10.0), .DP(27.0)) a (.errors(e1));
  ps_case #(.SP(27.0), .DP(10.0)) b (.errors(e2));
  ps_case #(.SP(10.0), .DP(10.0)) c (.errors(e3));
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("pulse_sync_tb.vcd");
      $dumpvars(0, pulse_sync_tb);
    end
    #1000000;
    if (e1 + e2 + e3 == 0) $display("TEST PASSED");
    else $display("TEST FAILED");
    $finish;
  end
endmodule
