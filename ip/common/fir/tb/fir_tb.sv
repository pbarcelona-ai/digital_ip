// ***************
// Filename: fir_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for fir. Loads random coefficients
//   and checks the output against a direct-form convolution model bit for
//   bit (including rounding and saturation) for random input with random
//   valid gaps, verifies the impulse response equals the coefficients,
//   that a coefficient change applies to later samples, saturation
//   flagging, and reset clearing of the delay line. Prints TEST PASSED on
//   success.
//   The test tasks are in tests/fir_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module fir_tb;
  localparam int T = 8, DW = 16, CW = 12, OW = 16, SH = 10;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic cwe = 0, vi = 0, vo, sat;
  logic [2:0] cidx = 0;
  logic signed [CW-1:0] cval = 0;
  logic signed [DW-1:0] din = 0;
  logic signed [OW-1:0] dout;
  fir #(
    .TAPS(T),
    .DATA_W(DW),
    .COEF_W(CW),
    .OUT_W(OW),
    .OUT_SHIFT(SH)
  ) dut (
    .clk,
    .rst_n,
    .coef_we_i(cwe),
    .coef_idx_i(cidx),
    .coef_i(cval),
    .valid_i(vi),
    .data_i(din),
    .valid_o(vo),
    .data_o(dout),
    .sat_o(sat)
  );
  int errors = 0, nout = 0, nsat = 0;
  logic signed [CW-1:0] cm [T]; // model state (transposed form, same as the DUT)
  longint zm [T];
  logic signed [OW-1:0] expq[$];
  bit satq[$];
  // test tasks: tests/fir_tests.sv
  `include "fir_tests.sv"
  always @(posedge clk) if (rst_n && vo) begin
    logic signed [OW-1:0] e;
    bit es;
    e = expq.pop_front();
    es = satq.pop_front();
    nout++;
    if (es) nsat++;
    if (dout !== e || sat !== es) begin
      errors++;
      $display("ERROR out %0d exp %0d sat %b/%b", dout, e, sat, es);
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("fir_tb.vcd");
      $dumpvars(0, fir_tb);
    end
    for (int k = 0; k < T; k++) begin
      cm[k] = 0;
      zm[k] = 0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    for (int k = 0; k < T; k++) setc(k, $urandom_range(0, 1500) - 750);
    // impulse response equals coefficients (scaled by 2^-SH with rounding)
    sample(1024);
    for (int i = 0; i < T + 2; i++) sample(0);
    // random data with gaps, some large values to saturate
    for (int n = 0; n < 3000; n++) begin
      if ($urandom_range(0, 3) == 0) begin repeat ($urandom_range(1, 3)) @(posedge clk); end
      sample($urandom_range(0, 65535) - 32768);
    end
    // coefficient change mid-stream
    setc(3, 1023);
    setc(0, -500);
    for (int n = 0; n < 200; n++) sample($urandom_range(0, 20000) - 10000);
    // saturation: full-scale input with large gain
    for (int k = 0; k < T; k++) setc(k, 1000);
    for (int n = 0; n < 20; n++) sample(32767);
    for (int n = 0; n < 20; n++) sample(-32768);
    repeat (5) @(posedge clk);
    if (nout != expq.size() + nout || expq.size() != 0) begin
      errors++;
      $display("ERROR %0d outputs unchecked", expq.size());
    end
    if (nsat == 0) begin
      errors++;
      $display("ERROR saturation not exercised");
    end
    // reset clears history: after reset a single sample sees only itself
    rst_n = 0;
    repeat (2) @(posedge clk);
    #1 rst_n = 1;
    for (int k = 0; k < T; k++) begin
      cm[k] = 0;
      zm[k] = 0;
    end
    for (int k = 0; k < T; k++) setc(k, 512);
    sample(1000);
    repeat (3) @(posedge clk);
    if (expq.size() != 0) begin
      errors++;
      $display("ERROR after reset");
    end
    $display("%0d outputs checked (%0d saturated)", nout, nsat);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
