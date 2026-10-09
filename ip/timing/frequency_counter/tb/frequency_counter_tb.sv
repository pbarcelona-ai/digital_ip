// ***************
// Filename: frequency_counter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for frequency_counter. Applies
//   asynchronous square waves of known frequency (1 MHz, 7.3 MHz, 20 MHz)
//   and checks the counted edges per gate window against the expected
//   value within plus/minus 1, plus disable behaviour and saturation of a
//   small counter. Prints TEST PASSED on success.
//   The test tasks are in tests/frequency_counter_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module frequency_counter_tb;
  logic clk = 0, rst_n = 0, en = 0, sig = 0; always #5 clk = ~clk;
  logic [31:0] cnt; logic v, ov; logic [31:0] gate = 10000;          // 100 us gate
  frequency_counter #(.COUNT_W(32), .GATE_W(32)) dut (.clk, .rst_n, .en_i(en), .gate_clks_i(gate), .sig_i(sig), .count_o(cnt), .valid_o(v), .over_o(ov));
  logic [7:0] cs; logic vs, ovs; logic sig2 = 0;
  frequency_counter #(.COUNT_W(8), .GATE_W(16)) dsat (.clk, .rst_n, .en_i(en), .gate_clks_i(16'd10000), .sig_i(sig2), .count_o(cs), .valid_o(vs), .over_o(ovs));
  real half = 500.0;
  always begin #(half) sig = ~sig; end
  always begin #(20.0) sig2 = ~sig2; end            // 25 MHz -> 2500 edges per gate: saturates 8 bit counter
  int errors = 0;
  // test tasks: tests/frequency_counter_tests.sv
  `include "frequency_counter_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("frequency_counter_tb.vcd"); $dumpvars(0, frequency_counter_tb); end
    repeat (3) @(posedge clk); rst_n = 1; en = 1;
    expect_edges(1.0); expect_edges(7.3); expect_edges(20.0);
    @(posedge vs); @(posedge vs); #1; check(cs == 8'hFF && ovs, "saturation not flagged");
    en = 0; repeat (10) @(posedge clk); #1 check(v == 0, "valid while disabled");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
