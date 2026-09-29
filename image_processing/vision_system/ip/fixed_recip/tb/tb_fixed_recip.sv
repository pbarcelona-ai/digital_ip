// ***************
// Filename: tb_fixed_recip.sv
// Author: Paul Barcelona
// Description: Self-checking standalone testbench for fixed_recip.
// Checks its output against an independent 64-bit integer
// division for powers of two, non-powers-of-two, the smallest
// and largest operands, and the operand=0 saturate case.
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_fixed_recip.sv
//
// Self-checking testbench for fixed_recip.sv (reusable IP -- no external
// package dependency; this module stands completely alone).
//
// Checks result = floor(2^32 / operand) against a plain 64-bit integer
// division computed independently in the testbench, for a spread of
// values (powers of two, non-powers-of-two, the smallest and largest
// representable operands, and operand=0 -- the documented saturate case).
// =============================================================================
`timescale 1ns/1ps
module tb_fixed_recip;
  localparam int W = 32;

  logic clk = 0, rst_n = 0, start = 0;
  logic [W-1:0] operand, result;
  logic busy, done;

  fixed_recip #(.W(W)) dut (.clk, .rst_n, .start, .operand, .result, .busy, .done);

  always #5 clk = ~clk;

  int checks, fails;

  task automatic check(input logic [W-1:0] op, input string name);
    logic [63:0] expected64;
    logic [W-1:0] expected;
    begin
      // Independent reference: floor(2^32 / op), op=0 treated as the
      // documented saturate-to-all-ones case (mirrors the RTL's own
      // divisor==0 guard, which substitutes divisor=1 -- floor(2^32/1)
      // overflows W bits, so the RTL saturates; reproduce that here
      // rather than actually computing 2^32/0).
      if (op == 0) begin
        expected = {W{1'b1}};
      end else begin
        expected64 = (64'h1_0000_0000) / {32'h0, op};
        expected = (expected64 > {W{1'b1}}) ? {W{1'b1}} : expected64[W-1:0];
      end

      @(posedge clk);
      operand = op; start = 1;
      @(posedge clk); start = 0;
      wait (done);

      checks = checks + 1;
      if (result !== expected) begin
        $display("[%s] FAIL: operand=0x%08h -> result=0x%08h, expected=0x%08h",
                   name, op, result, expected);
        fails = fails + 1;
      end else begin
        $display("[%s] PASS: operand=0x%08h (%.6f) -> result=0x%08h (%.6f)",
                   name, op, $itor(op)/65536.0, result, $itor(result)/65536.0);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    checks = 0; fails = 0;
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;

    check(32'h0001_0000, "1.0");           // expect 1.0
    check(32'h0002_0000, "2.0");           // expect 0.5
    check(32'h0000_8000, "0.5");           // expect 2.0
    check(32'h0000_4000, "0.25");          // expect 4.0
    check(32'h000A_0000, "10.0");          // expect 0.1
    check(32'h0064_0000, "100.0");         // expect 0.01
    check(32'h0000_0001, "smallest(~0)");  // expect saturate to all-ones
    check(32'hFFFF_FFFF, "largest");       // expect ~0
    check(32'h0000_0000, "zero(saturate)");
    check(32'h0003_0000, "3.0");           // non-power-of-two
    check(32'h0000_C000, "0.75");
    check(32'h0019_999A, "25.6");

    $display("=== fixed_recip smoke test: %0d/%0d checks passed ===", checks - fails, checks);
    if (fails == 0) $display(">>> PASS <<<");
    else             $display(">>> FAIL (%0d mismatches) <<<", fails);
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_fixed_recip);
  end
`endif
endmodule
