// ***************
// Filename: lfsr_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for lfsr. Verifies maximal-length
//   periods (PRBS7 = 127, PRBS15 = 32767, PRBS9 = 511), that a parallel
//   STEPS=8 instance equals eight serial steps, hold on disabled clocks,
//   load, and rejection of an all-zero seed (lockup_o). Prints TEST PASSED
//   on success.
//   The test tasks are in tests/lfsr_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module lfsr_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic en = 0, ld = 0;
  logic [14:0] seed = 0;
  logic [6:0] s7;
  logic [0:0] b7;
  logic lk7;
  logic [14:0] s15;
  logic [0:0] b15;
  logic lk15;
  logic [8:0] s9;
  logic [0:0] b9;
  logic lk9;
  logic [6:0] p7;
  logic [7:0] pb;
  logic lkp;
  lfsr #(.WIDTH(7), .TAPS(7'h60), .SEED(7'h7F)) u7 (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .seed_i(seed[6:0]),
    .state_o(s7),
    .bit_o(b7),
    .lockup_o(lk7)
  );
  lfsr #(.WIDTH(15), .TAPS(15'h6000), .SEED(15'h7FFF)) u15 (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .seed_i(seed),
    .state_o(s15),
    .bit_o(b15),
    .lockup_o(lk15)
  );
  lfsr #(.WIDTH(9), .TAPS(9'h110), .SEED(9'h1FF)) u9 (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .seed_i(seed[8:0]),
    .state_o(s9),
    .bit_o(b9),
    .lockup_o(lk9)
  );
  lfsr #(.WIDTH(7), .TAPS(7'h60), .SEED(7'h7F), .STEPS(8)) up (
    .clk,
    .rst_n,
    .en_i(en),
    .load_i(ld),
    .seed_i(seed[6:0]),
    .state_o(p7),
    .bit_o(pb),
    .lockup_o(lkp)
  );
  int errors = 0, n7, n15, n9;
  // test tasks: tests/lfsr_tests.sv
  `include "lfsr_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("lfsr_tb.vcd");
      $dumpvars(0, lfsr_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;
    check(s7 == 7'h7F && s15 == 15'h7FFF && s9 == 9'h1FF, "reset state");
    // hold while disabled
    repeat (3) @(posedge clk);
    #1 check(s7 == 7'h7F, "moved while disabled");
    en = 1;
    n7 = 0;
    // period measurement via state return to seed
    do begin
      @(posedge clk);
      #1 n7++;
    end
    while (s7 != 7'h7F && n7 < 1000);
    check(n7 == 127, $sformatf("PRBS7 period %0d", n7));
    rst_n = 0;
    en = 0;
    @(posedge clk);
    #1 rst_n = 1;
    en = 1;
    n9 = 0;
    do begin
      @(posedge clk);
      #1 n9++;
    end
    while (s9 != 9'h1FF && n9 < 5000);
    check(n9 == 511, $sformatf("PRBS9 period %0d", n9));
    // PRBS15 from a fresh reset
    rst_n = 0;
    en = 0;
    @(posedge clk);
    #1 rst_n = 1;
    en = 1;
    n15 = 0;
    do begin
      @(posedge clk);
      #1 n15++;
    end
    while (s15 != 15'h7FFF && n15 < 100000);
    check(n15 == 32767, $sformatf("PRBS15 period %0d", n15));
    // parallel 8 steps per clock equals 8 serial steps: compare after k clocks
    rst_n = 0;
    en = 0;
    @(posedge clk);
    #1 rst_n = 1;
    @(posedge clk);
    #1;
    begin
      logic [6:0] ss;
      logic [7:0] sbits;
      ss = 7'h7F;
      repeat (50) begin
        en = 1;
        @(posedge clk);
        #1 en = 0;
        for (int i = 0; i < 8; i++) begin
          sbits[i] = ss[6];
          ss = {ss[5:0], ^(ss & 7'h60)};
        end
        check(p7 == ss, $sformatf("parallel state %h serial %h", p7, ss));
      end
    end
    // serial bit stream from u7 with the parallel bits: first bit_o is the MSB before the shift
    // load and lockup
    en = 0;
    seed = 15'h0000;
    ld = 1;
    @(posedge clk);
    #1 ld = 0;
    check(lk7 == 1 && s7 == 7'h7F, "zero seed must lock-up flag and use SEED");
    seed = 15'h0055;
    ld = 1;
    @(posedge clk);
    #1 ld = 0;
    check(s7 == 7'h55 && lk7 == 0, "load");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #100000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
