// ***************
// Filename: lvds_tx.sv
// Author: FPGA Cores 4 U
// Description: LVDS display transmitter (OpenLDI / FPD-Link 7:1). Version
//   1.0.0. Maps timed video (rgb_i {B, G, R}, de_i, hs_i, vs_i) onto the
//   7-bit words of the LVDS data lanes for a 7:1 serializer (lvds_serializer
//   or vendor OSERDES) and LVDS output buffers. Bit 6 of each word is sent
//   first; the clock lane carries 1100011 (clk_word_o).
//     24 bpp, VESA (SPWG)               24 bpp, JEIDA
//     lane 0  G0 R5 R4 R3 R2 R1 R0      G2 R7 R6 R5 R4 R3 R2
//     lane 1  B1 B0 G5 G4 G3 G2 G1      B3 B2 G7 G6 G5 G4 G3
//     lane 2  DE VS HS B5 B4 B3 B2      DE VS HS B7 B6 B5 B4
//     lane 3  0  B7 B6 G7 G6 R7 R6      0  B1 B0 G1 G0 R1 R0
//   18 bpp (bpp18_i) uses lanes 0-2 with the six MSBs of each component in
//   the JEIDA positions (lane 3 is held at 0); the VESA / JEIDA choice
//   only matters for 24 bpp.
//   Single link: one pixel per word, a word every pixel clock (stb_o always
//   high), LVDS clock = pixel clock. Dual link (dual_i): pixel pairs, the
//   first (odd, 1-based) pixel of each pair on link A and the second on
//   link B, a word every second pixel clock (stb_o on alternate clocks),
//   LVDS clock = pixel clock / 2; the active area must start on an even
//   pixel clock of the line (even horizontal timing values). Outputs are
//   registered and change only with stb_o. Clock - pixel clock. Reset -
//   synchronous rst_n (active low).
// Date: 2026-10-02
module lvds_tx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        dual_i,
  input  logic        bpp18_i,
  input  logic        jeida_i,
  input  logic [23:0] rgb_i,
  input  logic        de_i,
  input  logic        hs_i,
  input  logic        vs_i,
  output logic [27:0] link_a_o,                 // lanes 0-3, lane i in [7i +: 7]
  output logic [27:0] link_b_o,                 // dual link only
  output logic [6:0]  clk_word_o,
  output logic        stb_o
);
  assign clk_word_o = 7'b1100011;

  function automatic logic [27:0] map(input logic [23:0] p, input logic de, input logic hs, input logic vs,
                                      input logic b18, input logic jei);
    logic [7:0] r, g, b;
    logic [6:0] l0, l1, l2, l3;
    r = p[7:0];
    g = p[15:8];
    b = p[23:16];
    if (b18 || jei) begin
      l0 = {g[2], r[7], r[6], r[5], r[4], r[3], r[2]};
      l1 = {b[3], b[2], g[7], g[6], g[5], g[4], g[3]};
      l2 = {de, vs, hs, b[7], b[6], b[5], b[4]};
      l3 = b18 ? 7'd0 : {1'b0, b[1], b[0], g[1], g[0], r[1], r[0]};
    end else begin
      l0 = {g[0], r[5], r[4], r[3], r[2], r[1], r[0]};
      l1 = {b[1], b[0], g[5], g[4], g[3], g[2], g[1]};
      l2 = {de, vs, hs, b[5], b[4], b[3], b[2]};
      l3 = {1'b0, b[7], b[6], g[7], g[6], r[7], r[6]};
    end
    map = {l3, l2, l1, l0};
  endfunction

  logic ph;
  logic [23:0] first_px;
  logic first_de;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ph <= 1'b0;
      first_px <= '0;
      first_de <= 1'b0;
      link_a_o <= '0;
      link_b_o <= '0;
      stb_o <= 1'b0;
    end else if (!dual_i) begin
      link_a_o <= map(rgb_i, de_i, hs_i, vs_i, bpp18_i, jeida_i);
      link_b_o <= '0;
      stb_o <= 1'b1;
      ph <= 1'b0;
    end else begin
      ph <= ~ph;
      stb_o <= ph;                                  // a pair is complete on odd phases
      if (!ph) begin
        first_px <= rgb_i;
        first_de <= de_i;
      end
      else begin
        link_a_o <= map(first_px, first_de, hs_i, vs_i, bpp18_i, jeida_i);
        link_b_o <= map(rgb_i, de_i, hs_i, vs_i, bpp18_i, jeida_i);
      end
    end
  end
endmodule
