// ***************
// Filename: mac_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking tests for signed/unsigned fixed-point MAC,
//   rounding, saturation, and IEEE-754 binary32 fused multiply-add behavior.
//   The test tasks are in tests/mac_tests.sv (`included).
// Date: 2026-09-30
`timescale 1ns/1ps
module mac_tb;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic fixed_valid_i = 1'b0, fixed_valid_o;
  logic signed [7:0] fixed_a_i = '0, fixed_b_i = '0, fixed_result_o;
  logic signed [15:0] fixed_acc_i = '0;
  logic fixed_overflow_o, fixed_underflow_o, fixed_inexact_o, fixed_invalid_o;

  mac #(
    .A_WIDTH(8), .B_WIDTH(8), .ACC_WIDTH(16), .OUT_WIDTH(8),
    .A_SIGNED(1), .B_SIGNED(1), .ACC_SIGNED(1), .OUT_SIGNED(1),
    .A_FRAC_BITS(4), .B_FRAC_BITS(4), .ACC_FRAC_BITS(4), .SATURATE(1)
  ) u_signed_fixed (
    .clk,
    .rst_n,
    .valid_i(fixed_valid_i),
    .a_i(fixed_a_i),
    .b_i(fixed_b_i),
    .acc_i(fixed_acc_i),
    .valid_o(fixed_valid_o),
    .result_o(fixed_result_o),
    .overflow_o(fixed_overflow_o),
    .underflow_o(fixed_underflow_o),
    .inexact_o(fixed_inexact_o),
    .invalid_o(fixed_invalid_o)
  );

  logic unsigned_valid_i = 1'b0, unsigned_valid_o;
  logic [7:0] unsigned_a_i = '0, unsigned_b_i = '0;
  logic [15:0] unsigned_acc_i = '0, unsigned_result_o;
  logic unsigned_overflow_o, unsigned_underflow_o, unsigned_inexact_o, unsigned_invalid_o;

  mac #(
    .A_WIDTH(8), .B_WIDTH(8), .ACC_WIDTH(16), .OUT_WIDTH(16),
    .A_SIGNED(0), .B_SIGNED(0), .ACC_SIGNED(0), .OUT_SIGNED(0)
  ) u_unsigned_fixed (
    .clk,
    .rst_n,
    .valid_i(unsigned_valid_i),
    .a_i(unsigned_a_i),
    .b_i(unsigned_b_i),
    .acc_i(unsigned_acc_i),
    .valid_o(unsigned_valid_o),
    .result_o(unsigned_result_o),
    .overflow_o(unsigned_overflow_o),
    .underflow_o(unsigned_underflow_o),
    .inexact_o(unsigned_inexact_o),
    .invalid_o(unsigned_invalid_o)
  );

  logic fp_valid_i = 1'b0, fp_valid_o;
  logic [31:0] fp_a_i = '0, fp_b_i = '0, fp_acc_i = '0, fp_result_o;
  logic fp_overflow_o, fp_underflow_o, fp_inexact_o, fp_invalid_o;

  mac #(
    .A_WIDTH(32), .B_WIDTH(32), .ACC_WIDTH(32), .OUT_WIDTH(32), .FLOATING_POINT(1)
  ) u_float32 (
    .clk,
    .rst_n,
    .valid_i(fp_valid_i),
    .a_i(fp_a_i),
    .b_i(fp_b_i),
    .acc_i(fp_acc_i),
    .valid_o(fp_valid_o),
    .result_o(fp_result_o),
    .overflow_o(fp_overflow_o),
    .underflow_o(fp_underflow_o),
    .inexact_o(fp_inexact_o),
    .invalid_o(fp_invalid_o)
  );

  int errors = 0;

  // test tasks: tests/mac_tests.sv
  `include "mac_tests.sv"

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    check_fixed(8'sd48, 8'sd32, 16'sd16, 8'sd112, 1'b0, 1'b0);
    check_fixed(-8'sd48, 8'sd32, 16'sd16, -8'sd80, 1'b0, 1'b0);
    check_fixed(8'sd1, 8'sd8, 16'sd0, 8'sd0, 1'b0, 1'b1);
    check_fixed(8'sd127, 8'sd127, 16'sd0, 8'sd127, 1'b1, 1'b1);
    check_unsigned(8'd200, 8'd3, 16'd1, 16'd601);

    check_float(32'h3f80_0000, 32'h4000_0000, 32'h4040_0000,
                32'h40a0_0000, 1'b0, 1'b0, 1'b0, 1'b0); // 1*2+3 = 5
    check_float(32'h3f80_0001, 32'h3f7f_fffe, 32'hbf80_0000,
                32'ha880_0000, 1'b0, 1'b0, 1'b0, 1'b0); // fused exact result: -2^-46
    check_float(32'h0000_0001, 32'h3f80_0000, 32'h0000_0000,
                32'h0000_0001, 1'b0, 1'b0, 1'b0, 1'b0); // smallest subnormal
    check_float(32'h0000_0001, 32'h3f00_0000, 32'h0000_0000,
                32'h0000_0000, 1'b0, 1'b1, 1'b1, 1'b0); // underflow tie rounds to even zero
    check_float(32'h0000_0000, 32'h7f80_0000, 32'h0000_0000,
                32'h7fc0_0000, 1'b0, 1'b0, 1'b0, 1'b1); // 0*infinity is invalid
    check_float(32'h7f7f_ffff, 32'h4000_0000, 32'h0000_0000,
                32'h7f80_0000, 1'b1, 1'b0, 1'b1, 1'b0); // overflow to infinity

    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("TEST FAILED (timeout)");
    $finish;
  end

  // Waveform dump: +vcd writes mac_tb.vcd (scripts/run_sim.sh --vcd / --wave, make wave)
  initial if ($test$plusargs("vcd")) begin
    $dumpfile("mac_tb.vcd");
    $dumpvars(0, mac_tb);
  end
endmodule