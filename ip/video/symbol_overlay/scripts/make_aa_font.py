#!/usr/bin/env python3
# ***************
# Filename: make_aa_font.py
# Author: FPGA Cores 4 U
# Description: Writes src/include/overlay_font_aa_s<S>.mem (S = 2, 4, 8), the
#   smooth (anti-aliased) font of symbol_overlay's labels and texts
#   (CTRL.FONT): DejaVu Sans Mono Bold rendered into the 3 x 5 font's cells
#   at scale S (4 S x 6 S pixels, so layouts do not change), 4 bits of
#   coverage per pixel (0 transparent .. 15 the text colour; the overlay
#   blends video and colour by it). Each glyph is drawn 4 x 4 oversampled
#   and box-filtered down; the baseline at 4.55 S, the em 5.7 S (capitals
#   about 4.2 S tall, descenders inside the cell).
#   File format: ASCII 32-126 in order, 6 S lines per glyph (top first), each
#   line 4 S hex digits, the leftmost pixel first.
#   The font: DejaVu Sans Mono Bold (Bitstream Vera / DejaVu licence: free
#   use and redistribution, also of derived bitmaps), as shipped with
#   matplotlib, or given with --ttf.
#   Usage: python3 scripts/make_aa_font.py [--ttf DejaVuSansMono-Bold.ttf]
# Date: 2026-10-20
# ***************
import argparse
import os
from pathlib import Path

SCALES = (2, 4, 8)
OVERSAMPLE = 4
EM = 5.7                        # font size, in scale units
BASELINE = 4.55                 # baseline from the cell's top, in scale units


def default_ttf() -> str:
    """matplotlib's copy of DejaVu Sans Mono Bold."""
    import matplotlib
    return os.path.join(os.path.dirname(matplotlib.__file__), "mpl-data", "fonts", "ttf",
                        "DejaVuSansMono-Bold.ttf")


def render(ttf: str, s: int) -> dict:
    """Coverage 0-15 of every glyph at scale s: {code: [rows of 4 s values]}."""
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
    o = OVERSAMPLE
    cw, ch = 4 * s, 6 * s
    font = ImageFont.truetype(ttf, round(EM * s * o))
    glyphs = {}
    for code in range(32, 127):
        img = Image.new("L", (cw * o, ch * o), 0)
        adv = font.getlength(chr(code))
        x = (cw * o - adv) / 2.0                                    # the advance centred in the cell
        ImageDraw.Draw(img).text((x, BASELINE * s * o), chr(code), fill=255, font=font, anchor="ls")
        a = np.asarray(img, np.float64).reshape(ch, o, cw, o).mean(axis=(1, 3)) / 255.0
        glyphs[code] = np.clip(np.round(a * 15), 0, 15).astype(int).tolist()
    return glyphs


def write_mem(path: Path, glyphs: dict) -> None:
    """The glyphs in the .mem format of the header (ASCII 32-126, one hex line per pixel row)."""
    lines = []
    for code in range(32, 127):
        for row in glyphs[code]:
            lines.append("".join("%X" % v for v in row))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> None:
    """Every scale's .mem file into src/include."""
    ap = argparse.ArgumentParser(description="symbol_overlay's smooth font (overlay_font_aa_s<S>.mem)")
    ap.add_argument("--ttf", default=None, help="TrueType font (default: matplotlib's DejaVu Sans Mono Bold)")
    a = ap.parse_args()
    ttf = a.ttf or default_ttf()
    inc = Path(__file__).resolve().parents[1] / "src" / "include"
    for s in SCALES:
        out = inc / f"overlay_font_aa_s{s}.mem"
        write_mem(out, render(ttf, s))
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
