// ***************
// Filename: fp32_fma.sv
// Author: FPGA Cores 4 U
// Description: Combinational IEEE-754 binary32 fused multiply-add. Uses an
//   exact fixed-scale accumulator so the product and addend are rounded only
//   once, to nearest with ties to even. Handles subnormals, infinities, NaNs,
//   invalid operations, overflow, underflow and inexact results.
// Date: 2026-09-30
module fp32_fma (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic [31:0] c_i,
  output logic [31:0] result_o,
  output logic        overflow_o,
  output logic        underflow_o,
  output logic        inexact_o,
  output logic        invalid_o
);
  localparam int EXACT_WIDTH = 555;

  logic [23:0] sig_a, sig_b, sig_c;
  logic [47:0] product;
  logic [EXACT_WIDTH-1:0] term_product, term_addend, magnitude, quotient;
  logic sign_product, sign_result;
  logic is_nan_a, is_nan_b, is_nan_c;
  logic is_snan_a, is_snan_b, is_snan_c;
  logic is_inf_a, is_inf_b, is_inf_c;
  logic is_zero_a, is_zero_b;
  logic round_guard, round_sticky, round_increment;
  logic [24:0] rounded_sig;
  integer exp_a_eff, exp_b_eff, exp_c_eff;
  integer product_shift, addend_shift, highest_bit, round_shift, exponent_field;

  always_comb begin
    result_o = '0;
    overflow_o = 1'b0;
    underflow_o = 1'b0;
    inexact_o = 1'b0;
    invalid_o = 1'b0;
    sig_a = '0;
    sig_b = '0;
    sig_c = '0;
    product = '0;
    term_product = '0;
    term_addend = '0;
    magnitude = '0;
    quotient = '0;
    sign_product = a_i[31] ^ b_i[31];
    sign_result = 1'b0;
    round_guard = 1'b0;
    round_sticky = 1'b0;
    round_increment = 1'b0;
    rounded_sig = '0;
    exp_a_eff = (a_i[30:23] == 0) ? 1 : a_i[30:23];
    exp_b_eff = (b_i[30:23] == 0) ? 1 : b_i[30:23];
    exp_c_eff = (c_i[30:23] == 0) ? 1 : c_i[30:23];
    product_shift = 0;
    addend_shift = 0;
    highest_bit = -1;
    round_shift = 0;
    exponent_field = 0;

    is_nan_a = (&a_i[30:23]) && (|a_i[22:0]);
    is_nan_b = (&b_i[30:23]) && (|b_i[22:0]);
    is_nan_c = (&c_i[30:23]) && (|c_i[22:0]);
    is_snan_a = is_nan_a && !a_i[22];
    is_snan_b = is_nan_b && !b_i[22];
    is_snan_c = is_nan_c && !c_i[22];
    is_inf_a = (&a_i[30:23]) && !(|a_i[22:0]);
    is_inf_b = (&b_i[30:23]) && !(|b_i[22:0]);
    is_inf_c = (&c_i[30:23]) && !(|c_i[22:0]);
    is_zero_a = !(|a_i[30:0]);
    is_zero_b = !(|b_i[30:0]);

    if (is_nan_a || is_nan_b || is_nan_c) begin
      result_o = 32'h7fc0_0000;
      invalid_o = is_snan_a || is_snan_b || is_snan_c;
    end else if ((is_inf_a && is_zero_b) || (is_inf_b && is_zero_a)) begin
      result_o = 32'h7fc0_0000;
      invalid_o = 1'b1;
    end else if (is_inf_a || is_inf_b) begin
      if (is_inf_c && (sign_product != c_i[31])) begin
        result_o = 32'h7fc0_0000;
        invalid_o = 1'b1;
      end else begin
        result_o = {sign_product, 8'hff, 23'b0};
      end
    end else if (is_inf_c) begin
      result_o = c_i;
    end else begin
      sig_a = (a_i[30:23] == 0) ? {1'b0, a_i[22:0]} : {1'b1, a_i[22:0]};
      sig_b = (b_i[30:23] == 0) ? {1'b0, b_i[22:0]} : {1'b1, b_i[22:0]};
      sig_c = (c_i[30:23] == 0) ? {1'b0, c_i[22:0]} : {1'b1, c_i[22:0]};
      product = {24'b0, sig_a} * {24'b0, sig_b};

      // All finite values are represented as signed integers in units of 2^-298.
      product_shift = exp_a_eff + exp_b_eff - 2;
      addend_shift = exp_c_eff + 148;
      term_product = {{(EXACT_WIDTH-48){1'b0}}, product} << product_shift;
      term_addend = {{(EXACT_WIDTH-24){1'b0}}, sig_c} << addend_shift;

      if (sign_product == c_i[31]) begin
        magnitude = term_product + term_addend;
        sign_result = sign_product;
      end else if (term_product >= term_addend) begin
        magnitude = term_product - term_addend;
        sign_result = sign_product;
      end else begin
        magnitude = term_addend - term_product;
        sign_result = c_i[31];
      end

      if (magnitude == '0) begin
        if ((term_product == '0) && (term_addend == '0) && (sign_product == c_i[31]))
          result_o = {sign_product, 31'b0};
        else
          result_o = 32'b0;
      end else begin
        for (integer bit_index = 0; bit_index < EXACT_WIDTH; bit_index++)
          if (magnitude[bit_index]) highest_bit = bit_index;

        if (highest_bit > 425) begin
          result_o = {sign_result, 8'hff, 23'b0};
          overflow_o = 1'b1;
          inexact_o = 1'b1;
        end else begin
          round_shift = (highest_bit >= 172) ? highest_bit - 23 : 149;
          quotient = magnitude >> round_shift;
          round_guard = magnitude[round_shift-1];
          round_sticky = |(magnitude << (EXACT_WIDTH - round_shift + 1));
          round_increment = round_guard && (round_sticky || quotient[0]);
          inexact_o = round_guard || round_sticky;
          rounded_sig = {1'b0, quotient[23:0]} + round_increment;

          if (highest_bit >= 172) begin
            exponent_field = highest_bit - 171;
            if (rounded_sig[24]) begin
              rounded_sig = rounded_sig >> 1;
              exponent_field = exponent_field + 1;
            end
            if (exponent_field >= 255) begin
              result_o = {sign_result, 8'hff, 23'b0};
              overflow_o = 1'b1;
              inexact_o = 1'b1;
            end else begin
              result_o = {sign_result, exponent_field[7:0], rounded_sig[22:0]};
            end
          end else if (rounded_sig[23]) begin
            result_o = {sign_result, 8'h01, 23'b0};
          end else begin
            result_o = {sign_result, 8'h00, rounded_sig[22:0]};
            underflow_o = inexact_o;
          end
        end
      end
    end
  end
endmodule