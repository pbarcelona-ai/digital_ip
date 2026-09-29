// ***************
// Filename: bilinear.sv
// Author: Paul Barcelona
// Description: Reusable IP. Standard 2x2 bilinear RGB888 interpolator
// using 8-bit fractional weights, in a 3-stage pipeline
// (3-cycle latency: weights, products, sum) sustaining one
// output pixel per clock.
// Date: September 26, 2026
// ***************
// =============================================================================
// bilinear.sv
//
// Standard 2x2 bilinear interpolation on RGB888 pixels using 8-bit
// (Q0.8, 1/256 resolution) fractional weights fx,fy (the low-order
// fractional bits of the source-pixel address computed by coord_gen).
//
//   out = TL*(1-fx)*(1-fy) + TR*fx*(1-fy) + BL*(1-fx)*fy + BR*fx*fy
//
// 3-stage pipeline (weights; the 12 pixel*weight products; then the sum,
// round and byte select). The sum has its own stage so no stage holds a
// DSP multiply AND the adder tree -- estimated worst path 7.75 ns.
// =============================================================================

module bilinear (
  input  logic               clk,
  input  logic                rst_n,
  input  logic                valid_in,
  input  logic  [7:0]         fx,          // Q0.8 horizontal fraction
  input  logic  [7:0]         fy,          // Q0.8 vertical fraction
  input  logic  [barrel_pkg::PIX_W-1:0]   tl, tr, bl, br,
  output logic                valid_out,
  output logic  [barrel_pkg::PIX_W-1:0]   pixel_out
);

  // TIMING NOTE: three register stages (latency 3). Data registers carry
  // no reset -- only the valid bits do -- so the synthesizer can absorb
  // the product registers into DSP48 MREG/PREG (an async reset on a data
  // register prevents that). Results are bit-identical to the earlier
  // two-stage version; only the sum was moved to its own stage.

  // ---- Stage A: bilinear weights ---------------------------------------
  logic        vA;
  logic [16:0] w00A, w10A, w01A, w11A;      // each up to 256*256
  logic [barrel_pkg::PIX_W-1:0] tlA, trA, blA, brA;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vA <= 1'b0;
    else        vA <= valid_in;
  end
  always_ff @(posedge clk) begin
    w00A <= (9'd256 - fx) * (9'd256 - fy);
    w10A <= ({1'b0,fx})   * (9'd256 - fy);
    w01A <= (9'd256 - fx) * ({1'b0,fy});
    w11A <= ({1'b0,fx})   * ({1'b0,fy});
    tlA <= tl; trA <= tr; blA <= bl; brA <= br;
  end

  // ---- Stage B1: raw per-channel, per-tap products (registered) --------
  // 12 products (3 channels x 4 taps): 8-bit pixel x 17-bit weight.
  logic        vB1;
  logic [24:0] prB1 [0:2][0:3];             // [channel R,G,B][tap TL,TR,BL,BR]
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vB1 <= 1'b0;
    else        vB1 <= vA;
  end
  always_ff @(posedge clk) begin
    prB1[0][0] <= tlA[23:16] * w00A;  prB1[0][1] <= trA[23:16] * w10A;
    prB1[0][2] <= blA[23:16] * w01A;  prB1[0][3] <= brA[23:16] * w11A;
    prB1[1][0] <= tlA[15:8]  * w00A;  prB1[1][1] <= trA[15:8]  * w10A;
    prB1[1][2] <= blA[15:8]  * w01A;  prB1[1][3] <= brA[15:8]  * w11A;
    prB1[2][0] <= tlA[7:0]   * w00A;  prB1[2][1] <= trA[7:0]   * w10A;
    prB1[2][2] <= blA[7:0]   * w01A;  prB1[2][3] <= brA[7:0]   * w11A;
  end

  // ---- Stage B2: sum the four products, round, take the result byte ----
  logic vB;
  logic [barrel_pkg::PIX_W-1:0] pixB;

  function automatic logic [7:0] sum_chan
    (input logic [24:0] p0, input logic [24:0] p1,
     input logic [24:0] p2, input logic [24:0] p3);
    logic [26:0] acc;
    begin
      acc = p0 + p1 + p2 + p3;
      acc = acc + 27'd32768;              // round-to-nearest before >>16
      sum_chan = acc[23:16];
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vB <= 1'b0;
    else        vB <= vB1;
  end
  always_ff @(posedge clk) begin
    pixB[23:16] <= sum_chan(prB1[0][0], prB1[0][1], prB1[0][2], prB1[0][3]);
    pixB[15:8]  <= sum_chan(prB1[1][0], prB1[1][1], prB1[1][2], prB1[1][3]);
    pixB[7:0]   <= sum_chan(prB1[2][0], prB1[2][1], prB1[2][2], prB1[2][3]);
  end

  assign valid_out = vB;
  assign pixel_out = pixB;

endmodule
