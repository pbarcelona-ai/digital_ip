// ***************
// Filename: bilinear.sv
// Author: Paul Barcelona
// Description: Reusable IP. Standard 2x2 bilinear RGB888 interpolator
// using 8-bit fractional weights, in a 2-stage pipeline
// (2-cycle latency) sustaining one output pixel per clock.
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
// 2-stage pipeline (weight products, then weighted accumulate) -- ample
// timing margin at 100 MHz.
// =============================================================================
import vision_system_pkg::*;

module bilinear (
  input  logic               clk,
  input  logic                rst_n,
  input  logic                valid_in,
  input  logic  [7:0]         fx,          // Q0.8 horizontal fraction
  input  logic  [7:0]         fy,          // Q0.8 vertical fraction
  input  logic  [PIX_W-1:0]   tl, tr, bl, br,
  output logic                valid_out,
  output logic  [PIX_W-1:0]   pixel_out
);

  // ---- Stage A: bilinear weights ---------------------------------------
  logic        vA;
  logic [16:0] w00A, w10A, w01A, w11A;      // each up to 256*256
  logic [PIX_W-1:0] tlA, trA, blA, brA;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vA <= 1'b0; w00A<='0; w10A<='0; w01A<='0; w11A<='0;
      tlA<='0; trA<='0; blA<='0; brA<='0;
    end else begin
      vA   <= valid_in;
      w00A <= (9'd256 - fx) * (9'd256 - fy);
      w10A <= ({1'b0,fx})   * (9'd256 - fy);
      w01A <= (9'd256 - fx) * ({1'b0,fy});
      w11A <= ({1'b0,fx})   * ({1'b0,fy});
      tlA <= tl; trA <= tr; blA <= bl; brA <= br;
    end
  end

  // ---- Stage B: per-channel weighted accumulate ------------------------
  logic vB;
  logic [PIX_W-1:0] pixB;

  function automatic logic [7:0] blend_chan
    (input logic [7:0] c00, input logic [7:0] c10,
     input logic [7:0] c01, input logic [7:0] c11,
     input logic [16:0] w00, input logic [16:0] w10,
     input logic [16:0] w01, input logic [16:0] w11);
    logic [26:0] acc;
    logic [7:0]  res;
    begin
      acc = c00*w00 + c10*w10 + c01*w01 + c11*w11;
      acc = acc + 27'd32768;              // round-to-nearest before >>16
      res = acc[23:16];
      return res;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vB <= 1'b0; pixB <= '0;
    end else begin
      vB <= vA;
      pixB[23:16] <= blend_chan(tlA[23:16], trA[23:16], blA[23:16], brA[23:16], w00A, w10A, w01A, w11A);
      pixB[15:8]  <= blend_chan(tlA[15:8],  trA[15:8],  blA[15:8],  brA[15:8],  w00A, w10A, w01A, w11A);
      pixB[7:0]   <= blend_chan(tlA[7:0],   trA[7:0],   blA[7:0],   brA[7:0],   w00A, w10A, w01A, w11A);
    end
  end

  assign valid_out = vB;
  assign pixel_out = pixB;

endmodule
