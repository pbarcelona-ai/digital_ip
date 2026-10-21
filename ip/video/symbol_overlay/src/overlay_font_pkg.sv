// ***************
// Filename: overlay_font_pkg.sv
// Author: FPGA Cores 4 U
// Description: 3 x 5 pixel font of symbol_overlay's text objects, generated
//   by scripts/make_font.py (edit the glyphs there). glyph(c) returns the 15
//   pixels of ASCII character c (32-126, lowercase letters with glyphs of
//   their own; anything else blank): bit r * 3 + col, row 0 at the top,
//   column 0 at the left. Characters sit in 4 x 6 cells (one blank column
//   and row of spacing).
// Date: 2026-10-11
package overlay_font_pkg;
  /* verilator lint_off UNUSEDPARAM */             // the font's geometry (documentation for users)
  localparam int GLYPH_W = 3, GLYPH_H = 5, CELL_W = 4, CELL_H = 6;
  /* verilator lint_on UNUSEDPARAM */
  function automatic logic [14:0] glyph(input logic [7:0] c);
    case (c)
      8'd32 : return 15'h0000;   // space
      8'd33 : return 15'h2092;   // !
      8'd34 : return 15'h002D;   // "
      8'd35 : return 15'h5F7D;   // #
      8'd36 : return 15'h3C9E;   // $
      8'd37 : return 15'h42A1;   // %
      8'd38 : return 15'h6AAA;   // &
      8'd39 : return 15'h0012;   // '
      8'd40 : return 15'h4494;   // (
      8'd41 : return 15'h1491;   // )
      8'd42 : return 15'h55D5;   // *
      8'd43 : return 15'h05D0;   // +
      8'd44 : return 15'h1400;   // ,
      8'd45 : return 15'h01C0;   // -
      8'd46 : return 15'h2000;   // .
      8'd47 : return 15'h12A4;   // /
      8'd48 : return 15'h7B6F;   // 0
      8'd49 : return 15'h749A;   // 1
      8'd50 : return 15'h73E7;   // 2
      8'd51 : return 15'h79E7;   // 3
      8'd52 : return 15'h49ED;   // 4
      8'd53 : return 15'h79CF;   // 5
      8'd54 : return 15'h7BCF;   // 6
      8'd55 : return 15'h24A7;   // 7
      8'd56 : return 15'h7BEF;   // 8
      8'd57 : return 15'h79EF;   // 9
      8'd58 : return 15'h0410;   // :
      8'd59 : return 15'h1410;   // ;
      8'd60 : return 15'h4454;   // <
      8'd61 : return 15'h0E38;   // =
      8'd62 : return 15'h1511;   // >
      8'd63 : return 15'h20A7;   // ?
      8'd64 : return 15'h63EF;   // @
      8'd65 : return 15'h5BEA;   // A
      8'd66 : return 15'h3AEB;   // B
      8'd67 : return 15'h624E;   // C
      8'd68 : return 15'h3B6B;   // D
      8'd69 : return 15'h72CF;   // E
      8'd70 : return 15'h12CF;   // F
      8'd71 : return 15'h6B4E;   // G
      8'd72 : return 15'h5BED;   // H
      8'd73 : return 15'h7497;   // I
      8'd74 : return 15'h2B24;   // J
      8'd75 : return 15'h5AED;   // K
      8'd76 : return 15'h7249;   // L
      8'd77 : return 15'h5BFD;   // M
      8'd78 : return 15'h5B6B;   // N
      8'd79 : return 15'h2B6A;   // O
      8'd80 : return 15'h12EB;   // P
      8'd81 : return 15'h6F6A;   // Q
      8'd82 : return 15'h5AEB;   // R
      8'd83 : return 15'h388E;   // S
      8'd84 : return 15'h2497;   // T
      8'd85 : return 15'h7B6D;   // U
      8'd86 : return 15'h2B6D;   // V
      8'd87 : return 15'h5FED;   // W
      8'd88 : return 15'h5AAD;   // X
      8'd89 : return 15'h24AD;   // Y
      8'd90 : return 15'h72A7;   // Z
      8'd91 : return 15'h324B;   // [
      8'd92 : return 15'h4889;   // backslash
      8'd93 : return 15'h6926;   // ]
      8'd94 : return 15'h002A;   // ^
      8'd95 : return 15'h7000;   // _
      8'd96 : return 15'h0011;   // `
      8'd97 : return 15'h7B98;   // a
      8'd98 : return 15'h3B59;   // b
      8'd99 : return 15'h6270;   // c
      8'd100: return 15'h6B74;   // d
      8'd101: return 15'h63D0;   // e
      8'd102: return 15'h25D4;   // f
      8'd103: return 15'h3D70;   // g
      8'd104: return 15'h5B59;   // h
      8'd105: return 15'h74C2;   // i
      8'd106: return 15'h2B04;   // j
      8'd107: return 15'h56E9;   // k
      8'd108: return 15'h7493;   // l
      8'd109: return 15'h5BF8;   // m
      8'd110: return 15'h5B58;   // n
      8'd111: return 15'h2B50;   // o
      8'd112: return 15'h1758;   // p
      8'd113: return 15'h4D70;   // q
      8'd114: return 15'h1270;   // r
      8'd115: return 15'h3870;   // s
      8'd116: return 15'h44BA;   // t
      8'd117: return 15'h6B68;   // u
      8'd118: return 15'h2B68;   // v
      8'd119: return 15'h7F68;   // w
      8'd120: return 15'h54A8;   // x
      8'd121: return 15'h1568;   // y
      8'd122: return 15'h77B8;   // z
      8'd123: return 15'h64D6;   // {
      8'd124: return 15'h2492;   // |
      8'd125: return 15'h3593;   // }
      8'd126: return 15'h0118;   // ~
      default: return 15'h0000;
    endcase
  endfunction
endpackage
