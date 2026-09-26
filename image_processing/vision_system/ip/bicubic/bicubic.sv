// ***************
// Filename: bicubic.sv
// Author: Paul Barcelona
// Description: Reusable IP. Separable Catmull-Rom (a=-0.5) bicubic
// RGB888 interpolator over a 4x4 tap footprint, in a 5-stage
// pipeline. Higher quality than bilinear but does not sustain
// 1 pixel/clock (see axis_out_ctrl.sv's gather FSM).
// Date: September 26, 2026
// ***************
// =============================================================================
// bicubic.sv
//
// Separable cubic-convolution (Catmull-Rom, a=-0.5) interpolation over a
// 4x4 tap footprint. Given the 16 source samples
//   p[row][col], row,col in {0(=y0-1/x0-1), 1(=y0/x0), 2(=y0+1/x0+1), 3(=y0+2/x0+2)}
// and the fractional distances tx,ty (Q16.16, unsigned, 0.0 <= t < 1.0)
// from tap column/row 1 (the "y0"/"x0" anchor) to the true sample point,
// computes the interpolated pixel via the standard separable form:
//   row_result[row] = sum_col p[row][col] * wx[col]
//   final           = sum_row row_result[row] * wy[row]
// where wx[],wy[] are the four Catmull-Rom weights for tx,ty respectively:
//   w(-1) = -0.5t^3 +     t^2 - 0.5t
//   w( 0) =  1.5t^3 - 2.5t^2       + 1
//   w(+1) = -1.5t^3 + 2.0t^2 + 0.5t
//   w(+2) =  0.5t^3 - 0.5t^2
// (weights sum to 1.0 for any t -- partition of unity). Unlike bilinear's
// weights, these can be negative (the classic cubic "overshoot" taps), so
// the final per-channel result is saturated back to [0,255].
//
// Fixed-point note: the row stage multiplies a PLAIN 8-bit pixel integer
// by a Q16.16 weight -- that product IS already correctly Q16.16-scaled
// (only one operand carries a scale factor), so it is a plain multiply,
// NOT qmul(). The column stage multiplies two ALREADY-Q16.16 quantities
// (row_result and wy), so it MUST use qmul() to remove the double scale
// factor. Getting this backwards is a classic separable-filter scaling
// bug -- see README for the worked derivation.
//
// 5-stage fixed pipeline (LATENCY=5), one job at a time, no backpressure
// (matches how the caller -- the bicubic gather FSM in axis_out_ctrl --
// only ever presents one set of taps at a time).
// =============================================================================
import vision_system_pkg::*;

module bicubic (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               valid_in,
  input  logic        [31:0] tx_q16,     // unsigned Q16.16, 0.0 <= t < 1.0
  input  logic        [31:0] ty_q16,
  input  logic [PIX_W-1:0]   p00, p01, p02, p03,   // row 0 (y0-1): cols x0-1,x0,x0+1,x0+2
  input  logic [PIX_W-1:0]   p10, p11, p12, p13,   // row 1 (y0)
  input  logic [PIX_W-1:0]   p20, p21, p22, p23,   // row 2 (y0+1)
  input  logic [PIX_W-1:0]   p30, p31, p32, p33,   // row 3 (y0+2)
  output logic                valid_out,
  output logic [PIX_W-1:0]    pixel_out
);

  localparam signed [31:0] C_NEG_HALF    = -32'sd32768;   // -0.5
  localparam signed [31:0] C_HALF        =  32'sd32768;   //  0.5
  localparam signed [31:0] C_ONE         =  32'sd65536;   //  1.0
  localparam signed [31:0] C_ONE_HALF    =  32'sd98304;   //  1.5
  localparam signed [31:0] C_NEG_ONE_HALF= -32'sd98304;   // -1.5
  localparam signed [31:0] C_TWO         =  32'sd131072;  //  2.0

  function automatic logic signed [31:0] cubic_w0
    (input logic signed [31:0] t, input logic signed [31:0] t2, input logic signed [31:0] t3);
    // -0.5t^3 + t^2 - 0.5t
    return qmul(C_NEG_HALF, t3) + t2 - qmul(C_HALF, t);
  endfunction
  function automatic logic signed [31:0] cubic_w1
    (input logic signed [31:0] t, input logic signed [31:0] t2, input logic signed [31:0] t3);
    // 1.5t^3 - 2.5t^2 + 1
    return qmul(C_ONE_HALF, t3) - qmul(32'sd163840 /*2.5*/, t2) + C_ONE;
  endfunction
  function automatic logic signed [31:0] cubic_w2
    (input logic signed [31:0] t, input logic signed [31:0] t2, input logic signed [31:0] t3);
    // -1.5t^3 + 2t^2 + 0.5t
    return qmul(C_NEG_ONE_HALF, t3) + qmul(C_TWO, t2) + qmul(C_HALF, t);
  endfunction
  function automatic logic signed [31:0] cubic_w3
    (input logic signed [31:0] t, input logic signed [31:0] t2, input logic signed [31:0] t3);
    // 0.5t^3 - 0.5t^2
    return qmul(C_HALF, t3) - qmul(C_HALF, t2);
  endfunction

  // ---- Stage 1: t^2, t^3 for both axes ----------------------------------
  logic               v1;
  logic signed [31:0] tx1, ty1, t2x1, t3x1, t2y1, t3y1;
  logic [PIX_W-1:0]   p00_1,p01_1,p02_1,p03_1,p10_1,p11_1,p12_1,p13_1,
                       p20_1,p21_1,p22_1,p23_1,p30_1,p31_1,p32_1,p33_1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; tx1<='0; ty1<='0; t2x1<='0; t3x1<='0; t2y1<='0; t3y1<='0;
      {p00_1,p01_1,p02_1,p03_1,p10_1,p11_1,p12_1,p13_1,
       p20_1,p21_1,p22_1,p23_1,p30_1,p31_1,p32_1,p33_1} <= '0;
    end else begin
      v1   <= valid_in;
      tx1  <= $signed(tx_q16);
      ty1  <= $signed(ty_q16);
      t2x1 <= qmul($signed(tx_q16), $signed(tx_q16));
      t3x1 <= qmul(qmul($signed(tx_q16), $signed(tx_q16)), $signed(tx_q16));
      t2y1 <= qmul($signed(ty_q16), $signed(ty_q16));
      t3y1 <= qmul(qmul($signed(ty_q16), $signed(ty_q16)), $signed(ty_q16));
      p00_1<=p00; p01_1<=p01; p02_1<=p02; p03_1<=p03;
      p10_1<=p10; p11_1<=p11; p12_1<=p12; p13_1<=p13;
      p20_1<=p20; p21_1<=p21; p22_1<=p22; p23_1<=p23;
      p30_1<=p30; p31_1<=p31; p32_1<=p32; p33_1<=p33;
    end
  end

  // ---- Stage 2: the 8 weights (wx[0:3], wy[0:3]) -------------------------
  logic               v2;
  logic signed [31:0] wx0_2, wx1_2, wx2_2, wx3_2, wy0_2, wy1_2, wy2_2, wy3_2;
  logic [PIX_W-1:0]   p00_2,p01_2,p02_2,p03_2,p10_2,p11_2,p12_2,p13_2,
                       p20_2,p21_2,p22_2,p23_2,p30_2,p31_2,p32_2,p33_2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v2 <= 1'b0; wx0_2<='0; wx1_2<='0; wx2_2<='0; wx3_2<='0;
      wy0_2<='0; wy1_2<='0; wy2_2<='0; wy3_2<='0;
      {p00_2,p01_2,p02_2,p03_2,p10_2,p11_2,p12_2,p13_2,
       p20_2,p21_2,p22_2,p23_2,p30_2,p31_2,p32_2,p33_2} <= '0;
    end else begin
      v2    <= v1;
      wx0_2 <= cubic_w0(tx1,t2x1,t3x1); wx1_2 <= cubic_w1(tx1,t2x1,t3x1);
      wx2_2 <= cubic_w2(tx1,t2x1,t3x1); wx3_2 <= cubic_w3(tx1,t2x1,t3x1);
      wy0_2 <= cubic_w0(ty1,t2y1,t3y1); wy1_2 <= cubic_w1(ty1,t2y1,t3y1);
      wy2_2 <= cubic_w2(ty1,t2y1,t3y1); wy3_2 <= cubic_w3(ty1,t2y1,t3y1);
      p00_2<=p00_1; p01_2<=p01_1; p02_2<=p02_1; p03_2<=p03_1;
      p10_2<=p10_1; p11_2<=p11_1; p12_2<=p12_1; p13_2<=p13_1;
      p20_2<=p20_1; p21_2<=p21_1; p22_2<=p22_1; p23_2<=p23_1;
      p30_2<=p30_1; p31_2<=p31_1; p32_2<=p32_1; p33_2<=p33_1;
    end
  end

  // ---- Stage 3: row_result[row] per channel (plain int * Q16.16) --------
  // row_result = p[row][0]*wx0 + p[row][1]*wx1 + p[row][2]*wx2 + p[row][3]*wx3
  function automatic logic signed [39:0] row_filter
    (input logic [7:0] c0, input logic [7:0] c1, input logic [7:0] c2, input logic [7:0] c3,
     input logic signed [31:0] w0, input logic signed [31:0] w1,
     input logic signed [31:0] w2, input logic signed [31:0] w3);
    logic signed [39:0] acc;
    begin
      acc = $signed({1'b0,c0})*w0 + $signed({1'b0,c1})*w1
          + $signed({1'b0,c2})*w2 + $signed({1'b0,c3})*w3;
      return acc;
    end
  endfunction

  logic               v3;
  logic signed [31:0] wx0_3,wx1_3,wx2_3,wx3_3,wy0_3,wy1_3,wy2_3,wy3_3;
  logic signed [39:0] rowR0_3,rowR1_3,rowR2_3,rowR3_3;   // R channel row results
  logic signed [39:0] rowG0_3,rowG1_3,rowG2_3,rowG3_3;   // G channel
  logic signed [39:0] rowB0_3,rowB1_3,rowB2_3,rowB3_3;   // B channel
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v3 <= 1'b0;
      wx0_3<='0;wx1_3<='0;wx2_3<='0;wx3_3<='0;wy0_3<='0;wy1_3<='0;wy2_3<='0;wy3_3<='0;
      rowR0_3<='0;rowR1_3<='0;rowR2_3<='0;rowR3_3<='0;
      rowG0_3<='0;rowG1_3<='0;rowG2_3<='0;rowG3_3<='0;
      rowB0_3<='0;rowB1_3<='0;rowB2_3<='0;rowB3_3<='0;
    end else begin
      v3 <= v2;
      wx0_3<=wx0_2; wx1_3<=wx1_2; wx2_3<=wx2_2; wx3_3<=wx3_2;
      wy0_3<=wy0_2; wy1_3<=wy1_2; wy2_3<=wy2_2; wy3_3<=wy3_2;
      // R = bits [23:16], G = [15:8], B = [7:0]
      rowR0_3 <= row_filter(p00_2[23:16],p01_2[23:16],p02_2[23:16],p03_2[23:16], wx0_2,wx1_2,wx2_2,wx3_2);
      rowR1_3 <= row_filter(p10_2[23:16],p11_2[23:16],p12_2[23:16],p13_2[23:16], wx0_2,wx1_2,wx2_2,wx3_2);
      rowR2_3 <= row_filter(p20_2[23:16],p21_2[23:16],p22_2[23:16],p23_2[23:16], wx0_2,wx1_2,wx2_2,wx3_2);
      rowR3_3 <= row_filter(p30_2[23:16],p31_2[23:16],p32_2[23:16],p33_2[23:16], wx0_2,wx1_2,wx2_2,wx3_2);

      rowG0_3 <= row_filter(p00_2[15:8], p01_2[15:8], p02_2[15:8], p03_2[15:8],  wx0_2,wx1_2,wx2_2,wx3_2);
      rowG1_3 <= row_filter(p10_2[15:8], p11_2[15:8], p12_2[15:8], p13_2[15:8],  wx0_2,wx1_2,wx2_2,wx3_2);
      rowG2_3 <= row_filter(p20_2[15:8], p21_2[15:8], p22_2[15:8], p23_2[15:8],  wx0_2,wx1_2,wx2_2,wx3_2);
      rowG3_3 <= row_filter(p30_2[15:8], p31_2[15:8], p32_2[15:8], p33_2[15:8],  wx0_2,wx1_2,wx2_2,wx3_2);

      rowB0_3 <= row_filter(p00_2[7:0],  p01_2[7:0],  p02_2[7:0],  p03_2[7:0],   wx0_2,wx1_2,wx2_2,wx3_2);
      rowB1_3 <= row_filter(p10_2[7:0],  p11_2[7:0],  p12_2[7:0],  p13_2[7:0],   wx0_2,wx1_2,wx2_2,wx3_2);
      rowB2_3 <= row_filter(p20_2[7:0],  p21_2[7:0],  p22_2[7:0],  p23_2[7:0],   wx0_2,wx1_2,wx2_2,wx3_2);
      rowB3_3 <= row_filter(p30_2[7:0],  p31_2[7:0],  p32_2[7:0],  p33_2[7:0],   wx0_2,wx1_2,wx2_2,wx3_2);
    end
  end

  // ---- Stage 4: column filter (qmul -- both operands Q16.16) ------------
  function automatic logic signed [31:0] col_filter
    (input logic signed [39:0] r0, input logic signed [39:0] r1,
     input logic signed [39:0] r2, input logic signed [39:0] r3,
     input logic signed [31:0] w0, input logic signed [31:0] w1,
     input logic signed [31:0] w2, input logic signed [31:0] w3);
    logic signed [31:0] acc;
    begin
      // row results fit comfortably in 32 bits for realistic pixel/weight
      // ranges; qmul takes 32-bit Q16.16 operands.
      acc = qmul(r0[31:0], w0) + qmul(r1[31:0], w1)
          + qmul(r2[31:0], w2) + qmul(r3[31:0], w3);
      return acc;
    end
  endfunction

  logic               v4;
  logic signed [31:0] finalR_4, finalG_4, finalB_4;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v4 <= 1'b0; finalR_4<='0; finalG_4<='0; finalB_4<='0;
    end else begin
      v4 <= v3;
      finalR_4 <= col_filter(rowR0_3,rowR1_3,rowR2_3,rowR3_3, wy0_3,wy1_3,wy2_3,wy3_3);
      finalG_4 <= col_filter(rowG0_3,rowG1_3,rowG2_3,rowG3_3, wy0_3,wy1_3,wy2_3,wy3_3);
      finalB_4 <= col_filter(rowB0_3,rowB1_3,rowB2_3,rowB3_3, wy0_3,wy1_3,wy2_3,wy3_3);
    end
  end

  // ---- Stage 5: round, >>16, clamp to [0,255] ----------------------------
  function automatic logic [7:0] finalize_chan(input logic signed [31:0] v);
    logic signed [31:0] rounded;
    logic signed [31:0] shifted;
    begin
      rounded = v + 32'sd32768;
      shifted = rounded >>> 16;
      if (shifted < 0)          return 8'd0;
      else if (shifted > 255)   return 8'd255;
      else                      return shifted[7:0];
    end
  endfunction

  logic             v5;
  logic [PIX_W-1:0] pix5;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v5 <= 1'b0; pix5 <= '0;
    end else begin
      v5 <= v4;
      pix5 <= {finalize_chan(finalR_4), finalize_chan(finalG_4), finalize_chan(finalB_4)};
    end
  end

  assign valid_out = v5;
  assign pixel_out = pix5;

endmodule
