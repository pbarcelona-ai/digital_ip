#!/usr/bin/env python3
# ***************
# Filename: make_font.py
# Author: FPGA Cores 4 U
# Description: Writes src/overlay_font_pkg.sv, the 3 x 5 pixel font of
#   symbol_overlay's text objects (ASCII 32-126; lowercase letters use the
#   capital glyphs). Each glyph is 15 bits, row 0 (top) in bits [2:0],
#   column 0 (left) in the lowest bit of a row. Edit GLYPHS and rerun to
#   change the font: python3 scripts/make_font.py
# Date: 2026-10-11
# ***************
from pathlib import Path

GLYPHS = {
    " ": "... ... ... ... ...", "!": ".#. .#. .#. ... .#.", '"': "#.# #.# ... ... ...",
    "#": "#.# ### #.# ### #.#", "$": ".## ##. .#. .## ##.", "%": "#.. ..# .#. #.. ..#",
    "&": ".#. #.# .#. #.# .##", "'": ".#. .#. ... ... ...", "(": "..# .#. .#. .#. ..#",
    ")": "#.. .#. .#. .#. #..", "*": "#.# .#. ### .#. #.#", "+": "... .#. ### .#. ...",
    ",": "... ... ... .#. #..", "-": "... ... ### ... ...", ".": "... ... ... ... .#.",
    "/": "..# ..# .#. #.. #..", "0": "### #.# #.# #.# ###", "1": ".#. ##. .#. .#. ###",
    "2": "### ..# ### #.. ###", "3": "### ..# ### ..# ###", "4": "#.# #.# ### ..# ..#",
    "5": "### #.. ### ..# ###", "6": "### #.. ### #.# ###", "7": "### ..# .#. .#. .#.",
    "8": "### #.# ### #.# ###", "9": "### #.# ### ..# ###", ":": "... .#. ... .#. ...",
    ";": "... .#. ... .#. #..", "<": "..# .#. #.. .#. ..#", "=": "... ### ... ### ...",
    ">": "#.. .#. ..# .#. #..", "?": "### ..# .#. ... .#.", "@": "### #.# ### #.. .##",
    "A": ".#. #.# ### #.# #.#", "B": "##. #.# ##. #.# ##.", "C": ".## #.. #.. #.. .##",
    "D": "##. #.# #.# #.# ##.", "E": "### #.. ##. #.. ###", "F": "### #.. ##. #.. #..",
    "G": ".## #.. #.# #.# .##", "H": "#.# #.# ### #.# #.#", "I": "### .#. .#. .#. ###",
    "J": "..# ..# ..# #.# .#.", "K": "#.# #.# ##. #.# #.#", "L": "#.. #.. #.. #.. ###",
    "M": "#.# ### ### #.# #.#", "N": "##. #.# #.# #.# #.#", "O": ".#. #.# #.# #.# .#.",
    "P": "##. #.# ##. #.. #..", "Q": ".#. #.# #.# ### .##", "R": "##. #.# ##. #.# #.#",
    "S": ".## #.. .#. ..# ##.", "T": "### .#. .#. .#. .#.", "U": "#.# #.# #.# #.# ###",
    "V": "#.# #.# #.# #.# .#.", "W": "#.# #.# ### ### #.#", "X": "#.# #.# .#. #.# #.#",
    "Y": "#.# #.# .#. .#. .#.", "Z": "### ..# .#. #.. ###", "[": "##. #.. #.. #.. ##.",
    "\\": "#.. #.. .#. ..# ..#", "]": ".## ..# ..# ..# .##", "^": ".#. #.# ... ... ...",
    "_": "... ... ... ... ###", "`": "#.. .#. ... ... ...", "{": ".## .#. ##. .#. .##",
    "|": ".#. .#. .#. .#. .#.", "}": "##. .#. .## .#. ##.", "~": "... ##. ..# ... ...",
}


def bits(g: str) -> int:
    v = 0
    for r, row in enumerate(g.split()):
        for c, ch in enumerate(row):
            if ch == "#":
                v |= 1 << (r * 3 + c)
    return v


def main() -> None:
    out = Path(__file__).resolve().parents[1] / "src" / "overlay_font_pkg.sv"
    rows = []
    for code in range(32, 127):
        ch = chr(code)
        g = GLYPHS.get(ch.upper() if "a" <= ch <= "z" else ch, GLYPHS["?"])
        name = "backslash" if ch == chr(92) else ("space" if ch == " " else ch)
        rows.append(f"      8'd{code:<3}: return 15'h{bits(g):04X};   // {name}")
    text = f"""// ***************
// Filename: overlay_font_pkg.sv
// Author: FPGA Cores 4 U
// Description: 3 x 5 pixel font of symbol_overlay's text objects, generated
//   by scripts/make_font.py (edit the glyphs there). glyph(c) returns the 15
//   pixels of ASCII character c (32-126; lowercase letters drawn as
//   capitals, anything else blank): bit r * 3 + col, row 0 at the top,
//   column 0 at the left. Characters sit in 4 x 6 cells (one blank column
//   and row of spacing).
// Date: 2026-10-11
package overlay_font_pkg;
  localparam int GLYPH_W = 3, GLYPH_H = 5, CELL_W = 4, CELL_H = 6;
  function automatic logic [14:0] glyph(input logic [7:0] c);
    case (c)
{chr(10).join(rows)}
      default: return 15'h0000;
    endcase
  endfunction
endpackage
"""
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
