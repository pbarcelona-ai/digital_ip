// ***************
// Filename: bicubic.sv
// Author: FPGA Cores 4 U
// Description: Reusable IP. Separable Catmull-Rom (a=-0.5) bicubic
// RGB888 interpolator over a 4x4 tap footprint, in an 18-stage
// pipeline (every multiply built on the mulq_s IP). Higher
// quality than bilinear but does not sustain 1 pixel/clock
// (see axis_out_ctrl.sv's gather FSM).
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
// 18-stage fixed pipeline (LATENCY=18; was 5 before the timing work --
// see the per-module headers below), one job at a time, no backpressure
// (matches how the caller -- the bicubic gather FSM in axis_out_ctrl --
// only ever presents one set of taps at a time).
// =============================================================================

// =============================================================================
// bicubic_weights: Catmull-Rom weights for ONE axis, latency 9.
//   w0 = -0.5t^3 + t^2 - 0.5t        w1 =  1.5t^3 - 2.5t^2 + 1
//   w2 = -1.5t^3 + 2t^2 + 0.5t       w3 =  0.5t^3 - 0.5t^2
// Every multiply is a mulq_s (2 cycles) followed by one saturate/combine
// register stage (barrel_pkg::qsat48). qsat48(mulq_s(a,b)) is exactly
// barrel_pkg::qmul(a,b), so the weights are bit-identical to the original
// single-stage formulation. Data registers carry no reset.
//   levels 1-3: t^2   levels 4-6: t^3   levels 7-9: constant products, w
// =============================================================================
module bicubic_weights (
  input  logic               clk,
  input  logic signed [31:0] t,
  output logic signed [31:0] w0, w1, w2, w3
);
  localparam signed [31:0] C_NEG_HALF     = -32'sd32768;   // -0.5
  localparam signed [31:0] C_HALF         =  32'sd32768;   //  0.5
  localparam signed [31:0] C_ONE          =  32'sd65536;   //  1.0
  localparam signed [31:0] C_ONE_HALF     =  32'sd98304;   //  1.5
  localparam signed [31:0] C_NEG_ONE_HALF = -32'sd98304;   // -1.5
  localparam signed [31:0] C_TWO          =  32'sd131072;  //  2.0
  localparam signed [31:0] C_TWO_HALF     =  32'sd163840;  //  2.5

  // levels 1-3: t^2 = qsat48(t*t) ; t delayed to level 3
  logic signed [47:0] m_t2;
  logic signed [31:0] tA1, tA2, tA3, t2_3;
  mulq_s u_t2 (.clk, .a(t), .b(t), .s(m_t2));
  always_ff @(posedge clk) begin
    tA1 <= t; tA2 <= tA1; tA3 <= tA2;
    t2_3 <= barrel_pkg::qsat48(m_t2);
  end

  // levels 4-6: t^3 = qsat48(t^2*t) ; t^2, t delayed to level 6
  logic signed [47:0] m_t3;
  logic signed [31:0] t2_4, t2_5, t2_6, tA4, tA5, tA6, t3_6;
  mulq_s u_t3 (.clk, .a(t2_3), .b(tA3), .s(m_t3));
  always_ff @(posedge clk) begin
    t2_4 <= t2_3; t2_5 <= t2_4; t2_6 <= t2_5;
    tA4  <= tA3;  tA5  <= tA4;  tA6  <= tA5;
    t3_6 <= barrel_pkg::qsat48(m_t3);
  end

  // levels 7-9: constant products, then saturate + combine into the weights
  logic signed [47:0] m_n05t3, m_15t3, m_n15t3, m_05t3, m_25t2, m_2t2, m_05t2, m_05t;
  logic signed [31:0] t2_7, t2_8;
  mulq_s u_n05t3 (.clk, .a(C_NEG_HALF),     .b(t3_6), .s(m_n05t3));
  mulq_s u_15t3  (.clk, .a(C_ONE_HALF),     .b(t3_6), .s(m_15t3));
  mulq_s u_n15t3 (.clk, .a(C_NEG_ONE_HALF), .b(t3_6), .s(m_n15t3));
  mulq_s u_05t3  (.clk, .a(C_HALF),         .b(t3_6), .s(m_05t3));
  mulq_s u_25t2  (.clk, .a(C_TWO_HALF),     .b(t2_6), .s(m_25t2));
  mulq_s u_2t2   (.clk, .a(C_TWO),          .b(t2_6), .s(m_2t2));
  mulq_s u_05t2  (.clk, .a(C_HALF),         .b(t2_6), .s(m_05t2));
  mulq_s u_05t   (.clk, .a(C_HALF),         .b(tA6),  .s(m_05t));
  always_ff @(posedge clk) begin
    t2_7 <= t2_6; t2_8 <= t2_7;
    w0 <= barrel_pkg::qsat48(m_n05t3) + t2_8 - barrel_pkg::qsat48(m_05t);
    w1 <= barrel_pkg::qsat48(m_15t3)  - barrel_pkg::qsat48(m_25t2) + C_ONE;
    w2 <= barrel_pkg::qsat48(m_n15t3) + barrel_pkg::qsat48(m_2t2)  + barrel_pkg::qsat48(m_05t);
    w3 <= barrel_pkg::qsat48(m_05t3)  - barrel_pkg::qsat48(m_05t2);
  end
endmodule

// =============================================================================
// bicubic_row: one 4-tap row filter of one colour channel, latency 4.
//   row = c0*w0 + c1*w1 + c2*w2 + c3*w3   (8-bit pixels x Q16.16 weights,
//   40-bit signed result).
// Each pixel*weight product is split (w = wh*2^16 + wl, wh signed 16, wl
// the UNSIGNED low half) into two single-DSP partial products registered
// in stage 1; stage 2 recombines (ph<<16)+pl per tap; stage 3 forms two
// pair sums; stage 4 the row sum. No stage holds more than one wide add.
// =============================================================================
module bicubic_row (
  input  logic               clk,
  input  logic        [7:0]  c0, c1, c2, c3,
  input  logic signed [31:0] w0, w1, w2, w3,
  output logic signed [39:0] row
);
  logic signed [8:0]  x0, x1, x2, x3;              // pixels as non-negative signed
  logic signed [15:0] h0, h1, h2, h3;              // weight high halves (signed)
  logic signed [16:0] l0, l1, l2, l3;              // weight low halves (non-negative)
  assign x0 = {1'b0, c0}; assign x1 = {1'b0, c1}; assign x2 = {1'b0, c2}; assign x3 = {1'b0, c3};
  assign h0 = w0[31:16];  assign h1 = w1[31:16];  assign h2 = w2[31:16];  assign h3 = w3[31:16];
  assign l0 = {1'b0, w0[15:0]}; assign l1 = {1'b0, w1[15:0]};
  assign l2 = {1'b0, w2[15:0]}; assign l3 = {1'b0, w3[15:0]};

  // stage 1: partial products (one DSP each)
  logic signed [24:0] ph0, ph1, ph2, ph3;
  logic signed [25:0] pl0, pl1, pl2, pl3;
  // stage 2: full per-tap products, 40-bit
  logic signed [39:0] q0, q1, q2, q3;
  // stage 3: pair sums
  logic signed [39:0] r01, r23;
  always_ff @(posedge clk) begin
    ph0 <= x0 * h0;  pl0 <= x0 * l0;
    ph1 <= x1 * h1;  pl1 <= x1 * l1;
    ph2 <= x2 * h2;  pl2 <= x2 * l2;
    ph3 <= x3 * h3;  pl3 <= x3 * l3;
    q0 <= ({{15{ph0[24]}}, ph0} <<< 16) + {{14{pl0[25]}}, pl0};
    q1 <= ({{15{ph1[24]}}, ph1} <<< 16) + {{14{pl1[25]}}, pl1};
    q2 <= ({{15{ph2[24]}}, ph2} <<< 16) + {{14{pl2[25]}}, pl2};
    q3 <= ({{15{ph3[24]}}, ph3} <<< 16) + {{14{pl3[25]}}, pl3};
    r01 <= q0 + q1;
    r23 <= q2 + q3;
    row <= r01 + r23;
  end
endmodule

// =============================================================================
// bicubic_col: column filter of one colour channel, latency 4.
//   out = qmul(r0,w0)+qmul(r1,w1)+qmul(r2,w2)+qmul(r3,w3), row results
//   truncated to 32 bits (qmul takes 32-bit Q16.16 operands), exactly as
//   before. mulq_s (2 cycles) -> saturate+pair-add -> final add.
// =============================================================================
module bicubic_col (
  input  logic               clk,
  input  logic signed [39:0] r0, r1, r2, r3,
  input  logic signed [31:0] w0, w1, w2, w3,
  output logic signed [31:0] fin
);
  // Signed 32-bit views of the truncated row results (a part-select is
  // UNSIGNED in Verilog; the original passed it through qmul's signed port).
  logic signed [31:0] a0, a1, a2, a3;
  assign a0 = r0[31:0]; assign a1 = r1[31:0]; assign a2 = r2[31:0]; assign a3 = r3[31:0];
  logic signed [47:0] m0, m1, m2, m3;
  mulq_s u_m0 (.clk, .a(a0), .b(w0), .s(m0));
  mulq_s u_m1 (.clk, .a(a1), .b(w1), .s(m1));
  mulq_s u_m2 (.clk, .a(a2), .b(w2), .s(m2));
  mulq_s u_m3 (.clk, .a(a3), .b(w3), .s(m3));
  logic signed [31:0] s01, s23;
  always_ff @(posedge clk) begin
    s01 <= barrel_pkg::qsat48(m0) + barrel_pkg::qsat48(m1);
    s23 <= barrel_pkg::qsat48(m2) + barrel_pkg::qsat48(m3);
    fin <= s01 + s23;
  end
endmodule

// =============================================================================
// bicubic: top level, latency 18.
//   levels 1-9    weights for both axes (bicubic_weights)
//   levels 10-13  row filters   (bicubic_row  x12: 3 channels x 4 rows)
//   levels 14-17  column filter (bicubic_col  x3)
//   level 18      round, >>16, clamp to [0,255]
// The 16 input taps are delayed 9 cycles (to meet the weights) through
// reset-free shift chains, which map onto SRL primitives. Only the valid
// chain is reset. Bit-identical to the original 5-stage formulation.
// =============================================================================
module bicubic (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               valid_in,
  input  logic        [31:0] tx_q16,     // unsigned Q16.16, 0.0 <= t < 1.0
  input  logic        [31:0] ty_q16,
  input  logic [barrel_pkg::PIX_W-1:0]   p00, p01, p02, p03,   // row 0 (y0-1): cols x0-1,x0,x0+1,x0+2
  input  logic [barrel_pkg::PIX_W-1:0]   p10, p11, p12, p13,   // row 1 (y0)
  input  logic [barrel_pkg::PIX_W-1:0]   p20, p21, p22, p23,   // row 2 (y0+1)
  input  logic [barrel_pkg::PIX_W-1:0]   p30, p31, p32, p33,   // row 3 (y0+2)
  output logic                valid_out,
  output logic [barrel_pkg::PIX_W-1:0]    pixel_out
);

  // ---- valid chain (18 stages) -------------------------------------------
  logic [17:0] vsr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vsr <= '0;
    else        vsr <= {vsr[16:0], valid_in};
  end

  // ---- weights (level 9) ---------------------------------------------------
  // Intermediate signed wires rather than $signed() written directly in the
  // port connection (Yosys 0.33 frontend signedness assertion).
  logic signed [31:0] tx_s, ty_s;
  assign tx_s = tx_q16;
  assign ty_s = ty_q16;
  logic signed [31:0] wx0, wx1, wx2, wx3, wy0, wy1, wy2, wy3;
  bicubic_weights u_wx (.clk, .t(tx_s), .w0(wx0), .w1(wx1), .w2(wx2), .w3(wx3));
  bicubic_weights u_wy (.clk, .t(ty_s), .w0(wy0), .w1(wy1), .w2(wy2), .w3(wy3));

  // ---- input tap delay: 16 taps x 24 bits, 9 cycles, no reset -----------
  localparam int TAPW = 16 * barrel_pkg::PIX_W;
  logic [TAPW-1:0] tap_in, tap1, tap2, tap3, tap4, tap5, tap6, tap7, tap8, tap9;
  assign tap_in = {p33,p32,p31,p30, p23,p22,p21,p20, p13,p12,p11,p10, p03,p02,p01,p00};
  always_ff @(posedge clk) begin
    tap1 <= tap_in; tap2 <= tap1; tap3 <= tap2; tap4 <= tap3; tap5 <= tap4;
    tap6 <= tap5;   tap7 <= tap6; tap8 <= tap7; tap9 <= tap8;
  end

  // ---- column weights carried through the four row-filter levels ---------
  logic signed [31:0] wy0_10, wy1_10, wy2_10, wy3_10, wy0_11, wy1_11, wy2_11, wy3_11;
  logic signed [31:0] wy0_12, wy1_12, wy2_12, wy3_12, wy0_13, wy1_13, wy2_13, wy3_13;
  always_ff @(posedge clk) begin
    wy0_10 <= wy0;    wy1_10 <= wy1;    wy2_10 <= wy2;    wy3_10 <= wy3;
    wy0_11 <= wy0_10; wy1_11 <= wy1_10; wy2_11 <= wy2_10; wy3_11 <= wy3_10;
    wy0_12 <= wy0_11; wy1_12 <= wy1_11; wy2_12 <= wy2_11; wy3_12 <= wy3_11;
    wy0_13 <= wy0_12; wy1_13 <= wy1_12; wy2_13 <= wy2_12; wy3_13 <= wy3_12;
  end

  // ---- row filters (level 13) and column filters (level 17) --------------
  // tap index = row*4 + col ; channel byte: R=[23:16] (ch0) G=[15:8] B=[7:0]
  logic signed [31:0] fin [0:2];
  genvar ch;
  generate
    for (ch = 0; ch < 3; ch = ch + 1) begin : g_ch
      logic signed [39:0] row0, row1, row2, row3;
      bicubic_row u_r0 (.clk,
        .c0(tap9[24*0  + (2-ch)*8 +: 8]), .c1(tap9[24*1  + (2-ch)*8 +: 8]),
        .c2(tap9[24*2  + (2-ch)*8 +: 8]), .c3(tap9[24*3  + (2-ch)*8 +: 8]),
        .w0(wx0), .w1(wx1), .w2(wx2), .w3(wx3), .row(row0));
      bicubic_row u_r1 (.clk,
        .c0(tap9[24*4  + (2-ch)*8 +: 8]), .c1(tap9[24*5  + (2-ch)*8 +: 8]),
        .c2(tap9[24*6  + (2-ch)*8 +: 8]), .c3(tap9[24*7  + (2-ch)*8 +: 8]),
        .w0(wx0), .w1(wx1), .w2(wx2), .w3(wx3), .row(row1));
      bicubic_row u_r2 (.clk,
        .c0(tap9[24*8  + (2-ch)*8 +: 8]), .c1(tap9[24*9  + (2-ch)*8 +: 8]),
        .c2(tap9[24*10 + (2-ch)*8 +: 8]), .c3(tap9[24*11 + (2-ch)*8 +: 8]),
        .w0(wx0), .w1(wx1), .w2(wx2), .w3(wx3), .row(row2));
      bicubic_row u_r3 (.clk,
        .c0(tap9[24*12 + (2-ch)*8 +: 8]), .c1(tap9[24*13 + (2-ch)*8 +: 8]),
        .c2(tap9[24*14 + (2-ch)*8 +: 8]), .c3(tap9[24*15 + (2-ch)*8 +: 8]),
        .w0(wx0), .w1(wx1), .w2(wx2), .w3(wx3), .row(row3));
      logic signed [31:0] f;
      bicubic_col u_c (.clk, .r0(row0), .r1(row1), .r2(row2), .r3(row3),
        .w0(wy0_13), .w1(wy1_13), .w2(wy2_13), .w3(wy3_13), .fin(f));
      assign fin[ch] = f;
    end
  endgenerate

  // ---- level 18: round, >>16, clamp to [0,255] ----------------------------
  function automatic logic [7:0] finalize_chan(input logic signed [31:0] v);
    logic signed [31:0] rounded;
    logic signed [31:0] shifted;
    begin
      rounded = v + 32'sd32768;
      shifted = rounded >>> 16;
      if (shifted < 0)          finalize_chan = 8'd0;
      else if (shifted > 255)   finalize_chan = 8'd255;
      else                      finalize_chan = shifted[7:0];
    end
  endfunction

  logic [barrel_pkg::PIX_W-1:0] pix18;
  always_ff @(posedge clk) begin
    pix18 <= {finalize_chan(fin[0]), finalize_chan(fin[1]), finalize_chan(fin[2])};
  end

  assign valid_out = vsr[17];
  assign pixel_out = pix18;

endmodule
