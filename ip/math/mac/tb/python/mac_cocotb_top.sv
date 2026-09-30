module mac_cocotb_top #(
  parameter int A_WIDTH = 16,
  parameter int B_WIDTH = 16,
  parameter int ACC_WIDTH = 40,
  parameter int OUT_WIDTH = ACC_WIDTH,
  parameter bit A_SIGNED = 1'b1,
  parameter bit B_SIGNED = 1'b1,
  parameter bit ACC_SIGNED = 1'b1,
  parameter bit OUT_SIGNED = ACC_SIGNED,
  parameter int A_FRAC_BITS = 0,
  parameter int B_FRAC_BITS = 0,
  parameter int ACC_FRAC_BITS = 0,
  parameter bit FLOATING_POINT = 1'b0,
  parameter bit ROUND_FIXED = 1'b1,
  parameter bit SATURATE = 1'b1
) (
  input logic clk,
  input logic rst_n,
  input logic valid_i,
  input logic [A_WIDTH-1:0] a_i,
  input logic [B_WIDTH-1:0] b_i,
  input logic [ACC_WIDTH-1:0] acc_i,
  output logic valid_o,
  output logic [OUT_WIDTH-1:0] result_o,
  output logic overflow_o,
  output logic underflow_o,
  output logic inexact_o,
  output logic invalid_o
);
  mac #(
    .A_WIDTH(A_WIDTH), .B_WIDTH(B_WIDTH), .ACC_WIDTH(ACC_WIDTH), .OUT_WIDTH(OUT_WIDTH),
    .A_SIGNED(A_SIGNED), .B_SIGNED(B_SIGNED), .ACC_SIGNED(ACC_SIGNED), .OUT_SIGNED(OUT_SIGNED),
    .A_FRAC_BITS(A_FRAC_BITS), .B_FRAC_BITS(B_FRAC_BITS), .ACC_FRAC_BITS(ACC_FRAC_BITS),
    .FLOATING_POINT(FLOATING_POINT), .ROUND_FIXED(ROUND_FIXED), .SATURATE(SATURATE)
  ) dut (.*);

  initial begin
    #20000;
    $finish;
  end
endmodule