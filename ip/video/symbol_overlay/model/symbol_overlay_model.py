"""symbol_overlay model (Python model of ip/video/symbol_overlay/src/symbol_overlay_top.sv), frame exact: the
output pixels of every frame equal the RTL's (the RTL may hold the input stream while it prepares a committed
set or a row: the pixels do not depend on the timing).

Registers (symbol_overlay_regs.json): CTRL [0] ENABLE (taken at every frame start) [2:1] LABEL_SCALE (labels
at 1 << LABEL_SCALE) [3] FONT (the smooth font for 2x and larger); COMMIT; STATUS [0] commit pending [31:16]
frames; FRAME_NUM (5 BCD digits: a write sets the number of the next frame, each frame start otherwise adds
one; reads the number of the current frame); objects 0..NOBJ-1 (16-31 in the second bank OBJ2_*): OBJ_CTRL,
OBJ_X {x1, x0}, OBJ_Y {y1, y0}, OBJ_COLOR, OBJ_LABEL; texts 0..NTXT-1: TXT_CTRL, TXT_POS {y, x}, TXT_COLOR,
TXT_CHARS (4 words). Coordinates are CW bits (the fields' upper bits are ignored).
A COMMIT applies at the next frame start: the object and text registers and CTRL's LABEL_SCALE / FONT as
they are then (one snapshot); a COMMIT written while that frame start is being prepared applies at the
following one.

The drawing of a pixel (x, y), in this order (layers):
  symbol: the enabled object of lowest index whose symbol covers the pixel: its colour, or with BLEND the
          50 % mix with the video ((v + c) >> 1 per channel);
  label:  the enabled object of lowest index with a label (OBJ_LABEL not 0) whose label cells cover the
          pixel: the pixel halved (backdrop), then the glyph in the object's colour;
  text:   the enabled text of lowest index whose cells cover the pixel: halved with BACKDROP, then the glyph.
Symbols (box x0..x1, y0..y1 inclusive; nothing when x0 > x1 or y0 > y1; lw = max(1, LINE_W), k = DASH_LOG2;
A = x1 - x0 + 1, B = y1 - y0 + 1, cx = (x0 + x1) >> 1, cy = (y0 + y1) >> 1, cl = max(3, min(A, B) >> 2);
dash_on(d) = ((d >> k) & 1) == 0; every symbol lies inside its box except the circle):
  TRIANGLE (OBJ_CTRL[7], any shape): W = x1 - x0, H = y1 - y0, S2 = x0 + x1; for row t = y - y0 (0..H):
    e(t) = W * t // H (H = 0: e = W), L(t) = (S2 - e(t)) >> 1, R(t) = (S2 + e(t) + 1) >> 1, and for t > 0
    Lp = L(t - 1), Rp = R(t - 1) (t = 0: Lp = L, Rp = R); bands: left x in [L, max(L, Lp - 1) + lw - 1], right
    x in [min(R, Rp + 1) - lw + 1, R], base t > H - lw and x in [L, R]; with DASHED each band is dashed with
    solid vertices: d = max(t, (S2 >> 1) - x) (left), max(t, x - ((S2 + 1) >> 1)) (right), x - x0 (base),
    length Le = max(H, W >> 1) (sides), W (base): solid when d < cl or Le - d < cl, else dash_on(d);
  SHAPE 0 rectangle outline: the band x < x0 + lw or x > x1 - lw or y < y0 + lw or y > y1 - lw; DASHED: on
    the top / bottom band dash_on(x - x0), else dash_on(y - y0), with CORNERS also where (x - x0 < cl or
    x1 - x < cl) and (y - y0 < cl or y1 - y < cl); TICKS: 2 lw pixels from each side's middle towards the
    centre, starting lw inside (x = cx, y in [y0 + lw, y0 + 3 lw - 1] or [y1 - 3 lw + 1, y1 - lw]; y = cy,
    x in [x0 + lw, x0 + 3 lw - 1] or [x1 - 3 lw + 1, x1 - lw]), not dashed;
  SHAPE 1 filled box;
  SHAPE 2 crosshair: |x - cx| < h or |y - cy| < h, h = (lw + 1) // 2 + (lw even); DASHED: dash_on(x - x0)
    or dash_on(y - y0);
  SHAPE 3 ellipse in doubled coordinates dx2 = 2 x - (x0 + x1), dy2 = 2 y - (y0 + y1): axes (a, b) = (A, B)
    with OVAL, else (R, R), R = max(A, B) (a circle round the box centre, may reach past the box);
    ai = max(a - 2 lw, 0), bi = max(b - 2 lw, 0); on the ring when dx2^2 b^2 + dy2^2 a^2 <= a^2 b^2 and not
    (ai > 0 and bi > 0 and dx2^2 bi^2 + dy2^2 ai^2 < ai^2 bi^2); DASHED: ((min(|dx2|, |dy2|) >> (k + 1)) & 1)
    == 0.
Labels: the label's characters are the bytes of OBJ_LABEL up to the first zero (byte 0 first), n of them, at scale s =
1 << LABEL_SCALE; tw = (4 n - 1) s; at lx = max(0, min(Wf - tw, cx - (tw >> 1))), ly = y1 + 2, or when
ly + 5 s > Hf, ly = max(0, y0 - 7 s); Wf, Hf the size of the frame before the one that applies the commit
(before any frame: 2**CW - 1). Cells 4 s x 6 s.
Texts: up to 16 characters (LENGTH), with FNUM then the frame number's 5 digits (leading zeros), cells
4 s x 6 s from TXT_POS, s = 1 << SCALE (1, 2, 4, 8).
Glyphs: s = 1 or FONT clear: the 3 x 5 font (scripts/make_font.py, overlay_font_pkg.sv; characters outside
32-126 blank) at s, its pixels in the colour; FONT and s = 2, 4, 8: the smooth font
(src/include/overlay_font_aa_s<s>.mem, scripts/make_aa_font.py; outside 32-126 '?'), coverage a 0-15 over
the whole cell: v = (v (15 - a) + c a + 7) // 15 per channel."""
import os

import numpy as np

from regs import RegMap, ip_regs

IP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOBJ, NTXT, CW = 32, 4, 13      # objects (two banks of 16), texts, coordinate bits


def obj_key(a, name, i):
    """Overlay object i's register value from a register snapshot a: objects 16-31 are the second bank
    (OBJ2_*)."""
    if i < 16:
        return a.get((name, i), 0)
    return a.get((name.replace("OBJ_", "OBJ2_"), i - 16), 0)


# ======================================================================= fonts

def load_font():
    """Glyphs of the 3 x 5 font from scripts/make_font.py (the generator of overlay_font_pkg.sv): {code:
    15 bits, row r column c in bit 3 r + c} for 32-126."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("make_font", os.path.join(IP_DIR, "scripts", "make_font.py"))
    mf = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mf)
    return {code: mf.bits(mf.GLYPHS.get(chr(code), mf.GLYPHS["?"])) for code in range(32, 127)}


FONT = load_font()


def font_cell(c, s):
    """The 3 x 5 glyph of character c in a 4 s x 6 s cell at scale s: bool array [6 s, 4 s]."""
    g = FONT.get(c, 0)
    cell = np.zeros((6, 4), bool)
    for r in range(5):
        for q in range(3):
            cell[r, q] = bool(g >> (3 * r + q) & 1)
    return np.kron(cell, np.ones((s, s), bool))


def load_aa_font():
    """The smooth font: {scale: array [95, 6 scale, 4 scale] of coverage 0-15}, from the
    overlay_font_aa_s<S>.mem files of scripts/make_aa_font.py (one glyph row per line)."""
    fonts = {}
    for s in (2, 4, 8):
        path = os.path.join(IP_DIR, "src", "include", f"overlay_font_aa_s{s}.mem")
        if not os.path.exists(path):
            continue
        with open(path, encoding="ascii") as fh:
            rows = [[int(c, 16) for c in ln.strip()] for ln in fh if ln.strip()]
        fonts[s] = np.array(rows, np.int32).reshape(95, 6 * s, 4 * s)
    return fonts


AA_FONT = load_aa_font()


# ======================================================================= the overlay

def _bcd_inc(v):
    d = [(v >> (4 * k)) & 15 for k in range(5)]
    for k in range(5):
        d[k] += 1
        if d[k] < 10:
            break
        d[k] = 0
    return sum(x << (4 * k) for k, x in enumerate(d))


class SymbolOverlay:
    """symbol_overlay: the register map, the active set (applied at a frame start after COMMIT) and the
    drawing of a frame (frame_start(), then draw(rgb))."""

    def __init__(self, nobj=NOBJ, ntxt=NTXT, cw=CW):
        self.r = RegMap(ip_regs(__file__, "symbol_overlay"), {"NOBJ": nobj, "NTXT": ntxt})
        self.nobj, self.ntxt, self.cw = nobj, ntxt, cw
        self.cmask = (1 << cw) - 1
        self.active = None                  # the applied snapshot (register values)
        self.enabled = False
        self.pending = False
        self.frames = 0
        self.fnum, self.fnum_set, self.fnum_pend = 0, 0, False
        self.prev_size = (self.cmask, self.cmask)   # (Wf, Hf): the last frame's size
        self.size = None                    # (Wf, Hf) of the applied set
        self.r.sts = lambda n, i: ({"COMMIT": int(self.pending), "STATUS": int(self.pending) |
                                    ((self.frames & 0xFFFF) << 16), "FRAME_NUM": self.fnum}.get(n, 0))
        self.r.on_write = self._w

    def _w(self, n, i, d):
        if n == "COMMIT" and d & 1:
            self.pending = True
        elif n == "FRAME_NUM":
            self.fnum_set, self.fnum_pend = d & 0xFFFFF, True

    def commit(self):
        self.pending = True

    def frame_start(self):
        """A frame starts: CTRL.ENABLE, a pending commit applied, the frame number."""
        r = self.r
        self.enabled = bool(r.get("CTRL") & 1)
        if self.pending:
            self.active = dict(r.value)
            self.active["CTRL"] = r.get("CTRL")
            self.size = self.prev_size
            self.pending = False
        self.fnum = self.fnum_set if self.fnum_pend else _bcd_inc(self.fnum)
        self.fnum_pend = False
        self.frames += 1

    def draw(self, rgb):
        """The output frame for input rgb [h, w, 3] (uint8, channel 0 = tdata[7:0])."""
        h, w = rgb.shape[:2]
        out = rgb.copy()
        self.prev_size = (w & self.cmask, h & self.cmask)
        if not self.enabled or self.active is None:
            return out
        a, cm = self.active, self.cmask
        ctrl = a["CTRL"]
        lab_s = 1 << ((ctrl >> 1) & 3)
        smooth = bool(ctrl & 8)
        objs = []
        for i in range(self.nobj):
            oc = obj_key(a, "OBJ_CTRL", i)
            xv, yv = obj_key(a, "OBJ_X", i), obj_key(a, "OBJ_Y", i)
            box = (xv & cm, (xv >> 16) & cm, yv & cm, (yv >> 16) & cm)
            colr = obj_key(a, "OBJ_COLOR", i)
            col = np.array([colr & 0xFF, (colr >> 8) & 0xFF, (colr >> 16) & 0xFF], np.int32)
            objs.append((oc, box, col, obj_key(a, "OBJ_LABEL", i)))
        # symbols: the lowest index covering a pixel (painted first, then the pixel is taken)
        taken = np.zeros((h, w), bool)
        for i in range(self.nobj):
            oc, box, col, _ = objs[i]
            if not oc & 1:
                continue
            win, m = symbol_window(oc, box, w, h)
            if win is None:
                continue
            y0, y1, x0, x1 = win
            m = m & ~taken[y0:y1, x0:x1]
            if not m.any():
                continue
            taken[y0:y1, x0:x1] |= m
            region = out[y0:y1, x0:x1]
            v = region[m].astype(np.int32)
            region[m] = ((v + col) >> 1 if oc & 16 else np.broadcast_to(col, v.shape)).astype(np.uint8)
        # labels, then texts: the lowest index covering a pixel
        items = []
        for i in range(self.nobj):
            oc, box, col, lab = objs[i]
            chars = label_chars(lab)
            if oc & 1 and chars:
                lx, ly = label_pos(box, len(chars), lab_s, self.size)
                items.append((chars, lx, ly, lab_s, col, True))
            else:
                items.append(None)
        self._layer(out, items, smooth)
        self.last_items = [items]                                       # (diagnostics: the frame's labels, texts)
        items = []
        for j in range(self.ntxt):
            tc = a.get(("TXT_CTRL", j), 0)
            if not tc & 1:
                items.append(None)
                continue
            pos = a.get(("TXT_POS", j), 0)
            colr = a.get(("TXT_COLOR", j), 0)
            col = np.array([colr & 0xFF, (colr >> 8) & 0xFF, (colr >> 16) & 0xFF], np.int32)
            n = min((tc >> 8) & 31, 16)
            chars = []
            for q in range(4):
                wd = a.get(("TXT_CHARS", 4 * j + q), 0)
                chars += [(wd >> (8 * b)) & 0xFF for b in range(4)]
            chars = chars[:n]
            if tc & 16:                                                 # the frame number, 5 digits
                chars += [0x30 + ((self.fnum >> (4 * d)) & 15) for d in range(4, -1, -1)]
            items.append((chars, pos & cm, (pos >> 16) & cm, 1 << ((tc >> 1) & 3), col, bool(tc & 8))
                         if chars else None)
        self._layer(out, items, smooth)
        self.last_items.append(items)
        return out

    @staticmethod
    def _layer(out, items, smooth):
        """A label / text layer: the item of lowest index covering a pixel: backdrop, then its glyph."""
        h, w = out.shape[:2]
        taken = np.zeros((h, w), bool)                                  # covered by a lower index
        for k, it in enumerate(items):
            if it is None:
                continue
            chars, x, y, s, col, backdrop = it
            x0, x1, y0, y1 = max(0, x), min(w, x + 4 * s * len(chars)), max(0, y), min(h, y + 6 * s)
            if x0 >= x1 or y0 >= y1:
                continue
            m = ~taken[y0:y1, x0:x1]
            taken[y0:y1, x0:x1] = True
            if not m.any():
                continue
            v = out[y0:y1, x0:x1].astype(np.int32)
            if backdrop:
                v = v >> 1
            aa = AA_FONT.get(s) if smooth else None
            cells = []
            for c in chars:
                if aa is not None:
                    cells.append(aa[c - 32] if 32 <= c < 127 else aa[ord("?") - 32])
                else:
                    cells.append(font_cell(c, s).astype(np.int32) * 15)
            g = np.concatenate(cells, axis=1)[y0 - y:y1 - y, x0 - x:x1 - x, None]
            if aa is not None:
                nv = (v * (15 - g) + col * g + 7) // 15
            else:
                nv = np.where(g > 0, col, v)
            region = out[y0:y1, x0:x1]
            region[m] = nv[m].astype(np.uint8)


def label_chars(lab):
    """The characters of an OBJ_LABEL word: its bytes from [7:0] up to the first zero."""
    chars = []
    for q in range(4):
        c = (lab >> (8 * q)) & 0xFF
        if not c:
            break
        chars.append(c)
    return chars


def label_pos(box, n, s, size):
    """(lx, ly) of a label of n characters at scale s under the box, in a frame of size (Wf, Hf)."""
    x0, x1, y0, y1 = box
    wf, hf = size
    tw = (4 * n - 1) * s
    lx = max(0, min(wf - tw, ((x0 + x1) >> 1) - (tw >> 1)))
    ly = y1 + 2
    if ly + 5 * s > hf:
        ly = max(0, y0 - 7 * s)
    return lx, ly


def symbol_window(ctrl, box, w, h):
    """(rows y0:y1, columns x0:x1 of the frame, mask) of the object's symbol, or (None, None)."""
    x0, x1, y0, y1 = box
    if x0 > x1 or y0 > y1:
        return None, None
    ex0, ex1, ey0, ey1 = x0, x1, y0, y1
    if (ctrl >> 1) & 3 == 3 and not ctrl & 128 and not ctrl & 32:   # a circle may reach past its box
        r = max(x1 - x0 + 1, y1 - y0 + 1)
        ex0, ex1 = ((x0 + x1 - r) >> 1) - 1, ((x0 + x1 + r) >> 1) + 1
        ey0, ey1 = ((y0 + y1 - r) >> 1) - 1, ((y0 + y1 + r) >> 1) + 1
    wx0, wx1, wy0, wy1 = max(0, ex0), min(w - 1, ex1), max(0, ey0), min(h - 1, ey1)
    if wx0 > wx1 or wy0 > wy1:
        return None, None
    yy, xx = np.mgrid[wy0:wy1 + 1, wx0:wx1 + 1]
    return (wy0, wy1 + 1, wx0, wx1 + 1), symbol_pixels(ctrl, box, xx, yy)


def symbol_pixels(ctrl, box, xx, yy):
    """The symbol at frame coordinates xx, yy (integer arrays): bool array."""
    x0, x1, y0, y1 = box
    lw = max(1, (ctrl >> 8) & 15)
    k = (ctrl >> 12) & 7
    dashed = bool(ctrl & 8)
    A, B = x1 - x0 + 1, y1 - y0 + 1
    cx, cy = (x0 + x1) >> 1, (y0 + y1) >> 1
    cl = max(3, min(A, B) >> 2)
    inside = (xx >= x0) & (xx <= x1) & (yy >= y0) & (yy <= y1)

    def on(d):
        return ((d >> k) & 1) == 0

    if ctrl & 128:                                                      # triangle
        W, H, S2 = x1 - x0, y1 - y0, x0 + x1
        t = yy - y0
        if H:
            e, ep = (W * t) // H, (W * np.maximum(t - 1, 0)) // H
        else:
            e = ep = np.full_like(t, W)
        L, R = (S2 - e) >> 1, (S2 + e + 1) >> 1
        Lp, Rp = (S2 - ep) >> 1, (S2 + ep + 1) >> 1
        Lp, Rp = np.where(t > 0, Lp, L), np.where(t > 0, Rp, R)
        left = (xx >= L) & (xx <= np.maximum(L, Lp - 1) + lw - 1)
        right = (xx >= np.minimum(R, Rp + 1) - lw + 1) & (xx <= R)
        base = (t > H - lw) & (xx >= L) & (xx <= R)
        if dashed:
            le = max(H, W >> 1)

            def band(d, length):
                return (d < cl) | (length - d < cl) | on(np.maximum(d, 0))
            left &= band(np.maximum(t, (S2 >> 1) - xx), le)
            right &= band(np.maximum(t, xx - ((S2 + 1) >> 1)), le)
            base &= band(xx - x0, W)
        return inside & (left | right | base)
    shape = (ctrl >> 1) & 3
    if shape == 0:
        hor = (yy < y0 + lw) | (yy > y1 - lw)
        edge = inside & (hor | (xx < x0 + lw) | (xx > x1 - lw))
        if dashed:
            d = np.where(hor, on(xx - x0), on(yy - y0))
            if ctrl & (1 << 15):
                d |= (((xx - x0) < cl) | ((x1 - xx) < cl)) & (((yy - y0) < cl) | ((y1 - yy) < cl))
            edge &= d
        if ctrl & 64:
            edge |= inside & (((xx == cx) & (((yy >= y0 + lw) & (yy <= y0 + 3 * lw - 1)) |
                                              ((yy >= y1 - 3 * lw + 1) & (yy <= y1 - lw)))) |
                              ((yy == cy) & (((xx >= x0 + lw) & (xx <= x0 + 3 * lw - 1)) |
                                              ((xx >= x1 - 3 * lw + 1) & (xx <= x1 - lw)))))
        return edge
    if shape == 1:
        return inside
    if shape == 2:
        hw = (lw + 1) // 2 + (1 if lw % 2 == 0 else 0)
        m = inside & ((np.abs(xx - cx) < hw) | (np.abs(yy - cy) < hw))
        if dashed:
            m &= on(xx - x0) | on(yy - y0)
        return m
    dx2, dy2 = 2 * xx - (x0 + x1), 2 * yy - (y0 + y1)
    if ctrl & 32:
        a, b = A, B
    else:
        a = b = max(A, B)
    ai, bi = max(a - 2 * lw, 0), max(b - 2 * lw, 0)
    dx2s, dy2s = dx2.astype(object) ** 2, dy2.astype(object) ** 2       # exact integers
    m = (dx2s * (b * b) + dy2s * (a * a) <= a * a * b * b).astype(bool)
    if ai and bi:
        m &= ~(dx2s * (bi * bi) + dy2s * (ai * ai) < ai * ai * bi * bi).astype(bool)
    if dashed:
        m &= ((np.minimum(np.abs(dx2), np.abs(dy2)) >> (k + 1)) & 1) == 0
    return m


def symbol_mask(ctrl, box, w, h):
    """The object's symbol in a w x h frame: bool array [h, w]."""
    m = np.zeros((h, w), bool)
    win, local = symbol_window(ctrl, box, w, h)
    if win is not None:
        y0, y1, x0, x1 = win
        m[y0:y1, x0:x1] = local
    return m


def draw_label(out, lab, box, col, scale=1, smooth=False):
    """A label (packed ASCII, character 0 in [7:0]) under the box, alone (pysim's reference drawing): the
    frame's own size, backdrop and glyphs as the overlay draws them."""
    chars = label_chars(lab)
    if not chars:
        return
    h, w = out.shape[:2]
    lx, ly = label_pos(box, len(chars), scale, (w, h))
    SymbolOverlay._layer(out, [(chars, lx, ly, scale, np.asarray(col, np.int32), True)], smooth)
