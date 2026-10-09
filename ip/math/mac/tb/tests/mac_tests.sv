// ***************
// Filename: mac_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the mac_tb testbench (mac_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     check_fixed
//     check_unsigned
//     check_float
// Date: 2026-10-08
// ***************
  task automatic check_fixed(
    input logic signed [7:0] a,
    input logic signed [7:0] b,
    input logic signed [15:0] acc,
    input logic signed [7:0] expected,
    input logic expected_overflow,
    input logic expected_inexact
  );
    @(negedge clk);
    fixed_valid_i = 1'b1;
    fixed_a_i = a;
    fixed_b_i = b;
    fixed_acc_i = acc;
    @(posedge clk);
    #1;
    if (!fixed_valid_o || fixed_result_o !== expected ||
        fixed_overflow_o !== expected_overflow || fixed_inexact_o !== expected_inexact ||
        fixed_underflow_o || fixed_invalid_o) begin
      errors++;
      $display("ERROR fixed MAC: got result=%0d overflow=%b inexact=%b", fixed_result_o, fixed_overflow_o, fixed_inexact_o);
    end
    @(negedge clk);
    fixed_valid_i = 1'b0;
  endtask

  task automatic check_unsigned(
    input logic [7:0] a,
    input logic [7:0] b,
    input logic [15:0] acc,
    input logic [15:0] expected
  );
    @(negedge clk);
    unsigned_valid_i = 1'b1;
    unsigned_a_i = a;
    unsigned_b_i = b;
    unsigned_acc_i = acc;
    @(posedge clk);
    #1;
    if (!unsigned_valid_o || unsigned_result_o !== expected || unsigned_overflow_o ||
        unsigned_underflow_o || unsigned_inexact_o || unsigned_invalid_o) begin
      errors++;
      $display("ERROR unsigned MAC: got result=%0d", unsigned_result_o);
    end
    @(negedge clk);
    unsigned_valid_i = 1'b0;
  endtask

  task automatic check_float(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] acc,
    input logic [31:0] expected,
    input logic expected_overflow,
    input logic expected_underflow,
    input logic expected_inexact,
    input logic expected_invalid
  );
    @(negedge clk);
    fp_valid_i = 1'b1;
    fp_a_i = a;
    fp_b_i = b;
    fp_acc_i = acc;
    @(posedge clk);
    #1;
    if (!fp_valid_o || fp_result_o !== expected || fp_overflow_o !== expected_overflow ||
        fp_underflow_o !== expected_underflow || fp_inexact_o !== expected_inexact ||
        fp_invalid_o !== expected_invalid) begin
      errors++;
      $display("ERROR float MAC: got result=%h flags=%b%b%b%b", fp_result_o,
               fp_overflow_o, fp_underflow_o, fp_inexact_o, fp_invalid_o);
    end
    @(negedge clk);
    fp_valid_i = 1'b0;
  endtask
