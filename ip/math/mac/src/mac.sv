// ***************
// Filename: mac.sv
// Author: FPGA Cores 4 U
// Description: One-cycle-latency multiply-accumulate unit. Fixed-point mode
//   supports independent operand widths/signs and Q-format binary points,
//   optional round-to-nearest-even, output saturation, and overflow/inexact
//   flags. Floating-point mode is IEEE-754 binary32 fused multiply-add with
//   round-to-nearest-even and overflow/underflow/inexact/invalid flags.
//   Clock - clk. Reset - synchronous active-low rst_n. Latency - one clock
//   from valid_i to valid_o. Throughput - one result per clock. Errors - bad
//   widths/fraction positions or non-binary32 floating-point widths rejected
//   at elaboration.
// Date: 2026-09-30
module mac #(
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
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  valid_i,
  input  logic [A_WIDTH-1:0]    a_i,
  input  logic [B_WIDTH-1:0]    b_i,
  input  logic [ACC_WIDTH-1:0]  acc_i,
  output logic                  valid_o,
  output logic [OUT_WIDTH-1:0]  result_o,
  output logic                  overflow_o,
  output logic                  underflow_o,
  output logic                  inexact_o,
  output logic                  invalid_o
);
  localparam int PRODUCT_WIDTH = A_WIDTH + B_WIDTH + 2;
  localparam int PRODUCT_SHIFT = A_FRAC_BITS + B_FRAC_BITS - ACC_FRAC_BITS;
  localparam int PRODUCT_LEFT_SHIFT = PRODUCT_SHIFT < 0 ? -PRODUCT_SHIFT : 0;
  localparam int PRODUCT_BASE_WIDTH = PRODUCT_WIDTH + PRODUCT_LEFT_SHIFT;
  localparam int BASE_WIDTH = PRODUCT_BASE_WIDTH > ACC_WIDTH ? PRODUCT_BASE_WIDTH : ACC_WIDTH;
  localparam int WORK_WIDTH = BASE_WIDTH + 1;

  if (A_WIDTH < 1 || B_WIDTH < 1 || ACC_WIDTH < 1 || OUT_WIDTH < 1 || OUT_WIDTH > WORK_WIDTH) begin : g_bad_width
    initial $error("mac: invalid data width");
  end
  if (A_FRAC_BITS < 0 || B_FRAC_BITS < 0 || ACC_FRAC_BITS < 0 ||
      A_FRAC_BITS >= A_WIDTH || B_FRAC_BITS >= B_WIDTH || ACC_FRAC_BITS >= ACC_WIDTH) begin : g_bad_fraction
    initial $error("mac: fixed-point fractional bits out of range");
  end
  if (FLOATING_POINT &&
      (A_WIDTH != 32 || B_WIDTH != 32 || ACC_WIDTH != 32 || OUT_WIDTH != 32)) begin : g_bad_float_width
    initial $error("mac: floating-point mode requires IEEE-754 binary32 widths");
  end

  logic signed [A_WIDTH:0] a_operand;
  logic signed [B_WIDTH:0] b_operand;
  logic signed [PRODUCT_WIDTH-1:0] a_product_operand, b_product_operand;
  logic signed [PRODUCT_WIDTH-1:0] product_fixed;
  logic signed [WORK_WIDTH-1:0] product_extended, accumulator_extended;
  logic signed [WORK_WIDTH-1:0] aligned_product, fixed_sum;
  logic [WORK_WIDTH-1:0] product_magnitude, product_quotient;
  logic fixed_overflow, fixed_inexact;
  logic [OUT_WIDTH-1:0] fixed_result;
  logic computed_overflow, computed_underflow, computed_inexact, computed_invalid;
  logic [OUT_WIDTH-1:0] computed_result;

  always_comb begin
    if (A_SIGNED)
      a_operand = $signed({a_i[A_WIDTH-1], a_i});
    else
      a_operand = $signed({1'b0, a_i});
    if (B_SIGNED)
      b_operand = $signed({b_i[B_WIDTH-1], b_i});
    else
      b_operand = $signed({1'b0, b_i});
    a_product_operand = a_operand;
    b_product_operand = b_operand;
    product_fixed = a_product_operand * b_product_operand;
    product_magnitude = '0;
    if (product_fixed[PRODUCT_WIDTH-1])
      product_magnitude[PRODUCT_WIDTH-1:0] = -product_fixed;
    else
      product_magnitude[PRODUCT_WIDTH-1:0] = product_fixed;
    product_extended = {{(WORK_WIDTH-PRODUCT_WIDTH){product_fixed[PRODUCT_WIDTH-1]}}, product_fixed};
    if (ACC_SIGNED)
      accumulator_extended = {{(WORK_WIDTH-ACC_WIDTH){acc_i[ACC_WIDTH-1]}}, acc_i};
    else
      accumulator_extended = {{(WORK_WIDTH-ACC_WIDTH){1'b0}}, acc_i};
  end

  generate
    if (PRODUCT_SHIFT > 0) begin : g_round_product
      logic guard_bit, sticky_bit, round_up;
      always_comb begin
        product_quotient = product_magnitude >> PRODUCT_SHIFT;
        guard_bit = product_magnitude[PRODUCT_SHIFT-1];
        sticky_bit = 1'b0;
        for (int bit_index = 0; bit_index < PRODUCT_SHIFT-1; bit_index++)
          sticky_bit = sticky_bit | product_magnitude[bit_index];
        round_up = ROUND_FIXED && guard_bit && (sticky_bit || product_quotient[0]);
        if (round_up)
          product_quotient = product_quotient + 1'b1;
        aligned_product = product_fixed[PRODUCT_WIDTH-1] ?
          -$signed(product_quotient) : $signed(product_quotient);
        fixed_inexact = guard_bit || sticky_bit;
      end
    end else begin : g_shift_product
      always_comb begin
        product_quotient = '0;
        if (PRODUCT_SHIFT < 0)
          aligned_product = product_extended <<< -PRODUCT_SHIFT;
        else
          aligned_product = product_extended;
        fixed_inexact = 1'b0;
      end
    end
  endgenerate

  logic signed [WORK_WIDTH-1:0] signed_max, signed_min;
  logic [WORK_WIDTH-1:0] unsigned_max;
  always_comb begin
    fixed_sum = accumulator_extended + aligned_product;
    signed_max = (WORK_WIDTH'(1) <<< (OUT_WIDTH-1)) - 1'b1;
    signed_min = -(WORK_WIDTH'(1) <<< (OUT_WIDTH-1));
    unsigned_max = '0;
    unsigned_max[OUT_WIDTH-1:0] = '1;
    fixed_result = fixed_sum[OUT_WIDTH-1:0];
    fixed_overflow = 1'b0;
    if (OUT_SIGNED) begin
      if (fixed_sum > signed_max) begin
        fixed_overflow = 1'b1;
        if (SATURATE) fixed_result = signed_max[OUT_WIDTH-1:0];
      end else if (fixed_sum < signed_min) begin
        fixed_overflow = 1'b1;
        if (SATURATE) fixed_result = signed_min[OUT_WIDTH-1:0];
      end
    end else if (fixed_sum[WORK_WIDTH-1]) begin
      fixed_overflow = 1'b1;
      if (SATURATE) fixed_result = '0;
    end else if ($unsigned(fixed_sum) > unsigned_max) begin
      fixed_overflow = 1'b1;
      if (SATURATE) fixed_result = unsigned_max[OUT_WIDTH-1:0];
    end
  end

  generate
    if (FLOATING_POINT) begin : g_float32
      logic [31:0] fp_result;
      logic fp_overflow, fp_underflow, fp_inexact, fp_invalid;
      fp32_fma u_fp32_fma (
        .a_i(a_i),
        .b_i(b_i),
        .c_i(acc_i),
        .result_o(fp_result),
        .overflow_o(fp_overflow),
        .underflow_o(fp_underflow),
        .inexact_o(fp_inexact),
        .invalid_o(fp_invalid)
      );
      always_comb begin
        computed_result = fp_result;
        computed_overflow = fp_overflow;
        computed_underflow = fp_underflow;
        computed_inexact = fp_inexact;
        computed_invalid = fp_invalid;
      end
    end else begin : g_fixed
      always_comb begin
        computed_result = fixed_result;
        computed_overflow = fixed_overflow;
        computed_underflow = 1'b0;
        computed_inexact = fixed_inexact || fixed_overflow;
        computed_invalid = 1'b0;
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_o <= 1'b0;
      result_o <= '0;
      overflow_o <= 1'b0;
      underflow_o <= 1'b0;
      inexact_o <= 1'b0;
      invalid_o <= 1'b0;
    end else begin
      valid_o <= valid_i;
      if (valid_i) begin
        result_o <= computed_result;
        overflow_o <= computed_overflow;
        underflow_o <= computed_underflow;
        inexact_o <= computed_inexact;
        invalid_o <= computed_invalid;
      end else begin
        overflow_o <= 1'b0;
        underflow_o <= 1'b0;
        inexact_o <= 1'b0;
        invalid_o <= 1'b0;
      end
    end
  end
endmodule