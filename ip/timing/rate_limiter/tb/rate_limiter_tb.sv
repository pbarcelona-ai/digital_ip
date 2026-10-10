// ***************
// Filename: rate_limiter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for rate_limiter. Saturates the
//   input and measures the output rate for several refill periods (average
//   within 1 percent), checks the initial burst equals the bucket size,
//   that data is unmodified, that downstream stalls do not consume tokens
//   and that period 0 removes the limit. Prints TEST PASSED on success.
//   The test tasks are in tests/rate_limiter_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module rate_limiter_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [15:0] per = 10;
  logic [5:0] burst = 4;
  logic [15:0] sd = 0, md;
  logic sv = 0, sr, mv, mr = 1;
  logic [5:0] tok;
  rate_limiter #(
    .DATA_W(16),
    .TOKEN_W(6),
    .PERIOD_W(16)
  ) dut (
    .clk,
    .rst_n,
    .refill_period_i(per),
    .burst_i(burst),
    .s_data_i(sd),
    .s_valid_i(sv),
    .s_ready_o(sr),
    .m_data_o(md),
    .m_valid_o(mv),
    .m_ready_i(mr),
    .tokens_o(tok)
  );
  int errors = 0, xf = 0;
  always @(posedge clk) if (mv && mr) begin
    xf++;
    if (md !== sd) begin
      errors++;
      $display("ERROR data");
    end
  end
  // test tasks: tests/rate_limiter_tests.sv
  `include "rate_limiter_tests.sv"
  int g;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("rate_limiter_tb.vcd");
      $dumpvars(0, rate_limiter_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    #1;
    // initial burst: with a saturated source the first `burst` words pass back-to-back
    sv = 1;
    sd = 16'h1234;
    run(4, g);
    check(g == 4, $sformatf("initial burst %0d", g));
    // long-term rate
    run(50, g);
    run(2000, g);
    check(g >= 196 && g <= 204, $sformatf("period 10: %0d words in 2000 clocks (exp 200)", g));
    per = 4;
    run(100, g);
    run(2000, g);
    check(g >= 495 && g <= 505, $sformatf("period 4: %0d (exp 500)", g));
    per = 33;
    run(200, g);
    run(3300, g);
    check(g >= 99 && g <= 101, $sformatf("period 33: %0d (exp 100)", g));
    // stall does not consume tokens: stall long, then a burst of `burst` words
    per = 20;
    sv = 0;
    repeat (400) @(posedge clk);
    mr = 0;
    sv = 1;
    repeat (100) @(posedge clk);
    check(tok == burst, $sformatf("tokens consumed during stall %0d", tok));
    mr = 1;
    run(4, g);
    check(g == 4, $sformatf("burst after stall %0d", g));
    // unlimited
    per = 0;
    run(100, g);
    check(g == 100, $sformatf("unlimited %0d", g));
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
