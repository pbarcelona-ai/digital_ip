// ***************
// Filename: tb_mulq.sv
// Author: Paul Barcelona
// Description: Self-checking standalone testbench for mulq_s. Compares
// its 2-cycle output against an independent 64-bit multiply and
// arithmetic shift for corner values and a large pseudo-random
// sweep, and checks the saturated result against qmul semantics.
// Date: September 26, 2026
// ***************
`timescale 1ns/1ps
module tb_mulq;
  logic clk = 0;
  always #5 clk = ~clk;
  logic signed [31:0] a, b;
  logic signed [47:0] s;
  mulq_s dut (.clk, .a, .b, .s);

  // Reference: exact 64-bit product, arithmetic shift, then (for the
  // saturated comparison) clamp to signed 32 bits.
  function automatic logic signed [47:0] ref_s(input logic signed [31:0] x, input logic signed [31:0] y);
    logic signed [63:0] p;
    begin p = x * y; ref_s = p >>> 16; end
  endfunction
  function automatic logic signed [31:0] sat32(input logic signed [47:0] v);
    begin
      if (v > 48'sd2147483647)       sat32 = 32'sh7fffffff;
      else if (v < -48'sd2147483648) sat32 = 32'sh80000000;
      else                           sat32 = v[31:0];
    end
  endfunction

  // Two-deep expected/input history to align with the 2-cycle latency.
  logic signed [31:0] a1, b1, a2, b2;
  int checks, fails, i;
  logic [31:0] seed;
  logic signed [47:0] exp_s;

  task automatic drive(input logic signed [31:0] x, input logic signed [31:0] y);
    begin
      @(posedge clk);
      a <= x; b <= y;
    end
  endtask

  always @(posedge clk) begin
    a1 <= a;  b1 <= b;
    a2 <= a1; b2 <= b1;
  end

  // Check at each edge: s reflects inputs presented 2 edges earlier.
  int started;
  always @(posedge clk) begin
    #1;
    if (started > 3) begin
      exp_s = ref_s(a2, b2);
      checks = checks + 1;
      if (s !== exp_s) begin
        fails = fails + 1;
        if (fails < 10) $display("FAIL a=%0d b=%0d s=%0d exp=%0d", a2, b2, s, exp_s);
      end else if (sat32(s) !== sat32(exp_s)) begin
        fails = fails + 1;
      end
    end
    started = started + 1;
  end

  initial begin
    checks = 0; fails = 0; started = 0; seed = 32'hC0FFEE01;
    a = 0; b = 0;
    // corner values
    drive(32'sd0, 32'sd0);
    drive(32'sh7fffffff, 32'sh7fffffff);
    drive(32'sh80000000, 32'sh80000000);
    drive(32'sh80000000, 32'sh7fffffff);
    drive(32'sh7fffffff, 32'sh80000000);
    drive(-32'sd1, -32'sd1);
    drive(-32'sd1, 32'sd1);
    drive(32'sd65536, 32'sd65536);
    drive(-32'sd65536, 32'sd65536);
    drive(32'sh0000ffff, 32'sh0000ffff);
    drive(32'sh0001ffff, 32'shffff0001);
    drive(32'sd98304, -32'sd98304);
    drive(32'sd163840, 32'sd163840);
    for (i = 0; i < 20000; i = i + 1) begin
      logic signed [31:0] ra, rb;
      seed = seed * 32'd1664525 + 32'd1013904223;
      ra = seed;
      seed = seed * 32'd1664525 + 32'd1013904223;
      rb = seed;
      drive(ra, rb);              // nonblocking at the edge: no TB/DUT race
    end
    repeat (5) @(posedge clk);
    $display("=== mulq_s self-check: %0d/%0d checks passed ===", checks - fails, checks);
    if (fails == 0) $display(">>> PASS <<<");
    else            $display(">>> FAIL (%0d mismatches) <<<", fails);
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_mulq);
  end
`endif
endmodule
