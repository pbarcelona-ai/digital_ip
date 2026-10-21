"""object_tracker model (Python model of ip/video/object_tracker/src/object_tracker_top.sv), frame exact: the
registers after each frame (tb/python compares them with the RTL). The measurement of a frame: the pixel test
(luma above / below THRESH, or colour: Y / Cb / Cr ranges and SAT_MIN, or with CTRL.SKIN_LUT [15] the 32 x 32
chroma table: word (Cr - 112) >> 1, bit (Cb - 96) >> 1), combined with the motion bit (CTRL [13:12]: test, or,
and, motion), runs of RUN.MIN-MAX pixels judged by their whole length (a second term on the edge bit with CTRL
[14], RUN_B, its own blob slots), the search window (only the counted runs' pixels inside it are measured),
totals (COUNT, box, sums) and NBLOB blobs grouped in one pass in the order the runs close (BLOB_CFG: gap, vertical
gap, minimum pixels kept). STATUS [1] FULL_WIN [15:8] BLOB_LOST [31:16] FRAMES; BLOB_X / BLOB_Y / BLOB_N of an
empty slot read 0. A frame is measured when CTRL.EN is set; the configuration must not change during a frame
(the RTL reads it as the pixels arrive; the window is taken at the frame start) and FRAME_SIZE must be the
frame's size."""
import numpy as np

from pixel import chroma
from regs import RegMap, ip_regs

NBLOB = 8


def term_runs(obj, rmin, rmax, term):
    """Counted runs (y, closing column, term, x0, x1): judged by their whole length."""
    h, w = obj.shape
    pad = np.zeros((h, w + 2), np.int8)
    pad[:, 1:-1] = obj
    dif = np.diff(pad, axis=1)
    out = []
    for (y, a), (_, e) in zip(np.argwhere(dif == 1), np.argwhere(dif == -1)):
        ln = e - a
        if ln >= max(rmin, 1) and (rmax == 0 or ln <= rmax):
            out.append((int(y), int(e) if e < w else w - 1, term, int(a), int(e) - 1))
    return out


class ObjectTracker:
    """object_tracker: pixel test (luma or colour, combined with the motion bit), run filter, search
    window, totals and NBLOB blobs grouped in one pass."""

    def __init__(self):
        self.r = RegMap(ip_regs(__file__, "object_tracker"))
        self.r.sts = self.sts
        self.frames = 0
        self.res = dict(n=0, x0=0xFFFF, x1=0, y0=0xFFFF, y1=0, sx=0, sy=0, lost=0)
        self.blobs = [(0, 0, 0, 0, 0)] * NBLOB
        self.full_win = False

    def measure(self, rgb, edge, mot):
        r = self.r
        ctrl = r.get("CTRL")
        if not ctrl & 1:
            return
        h, w = rgb.shape[:2]
        y, cb, cr, sat = chroma(rgb)
        if ctrl & 4:                                                    # colour mode
            def rng(v, reg):
                lo, hi = r.get(reg) & 0xFF, (r.get(reg) >> 8) & 0xFF
                return (v >= lo) & (v <= hi)
            if ctrl & (1 << 15):                                        # SKIN_LUT: the learned chroma table
                bi, ri = (cb - 96) >> 1, (cr - 112) >> 1
                inside = (bi >= 0) & (bi < 32) & (ri >= 0) & (ri < 32)
                words = np.array([r.get("SKIN_LUT", k) for k in range(32)], np.int64)
                bit = (words[np.clip(ri, 0, 31)] >> np.clip(bi, 0, 31)) & 1
                test = rng(y, "Y_RANGE") & inside & (bit == 1)
            else:
                test = rng(y, "Y_RANGE") & rng(cb, "CB_RANGE") & rng(cr, "CR_RANGE") & (sat >= r.get("SAT_MIN"))
        else:
            thr = r.get("THRESH")
            test = (y < thr) if ctrl & 2 else (y > thr)
        fa = (ctrl >> 12) & 3
        a = [test, test | mot, test & mot, mot][fa]
        run = r.get("RUN")
        rmin, rmax = run & 0xFFF, (run >> 16) & 0xFFF
        if rmin == 0:
            rmin = (ctrl >> 8) & 15
        terms = [(a, rmin, rmax)]
        if ctrl & (1 << 14):
            rb = r.get("RUN_B")
            terms.append((edge, rb & 0xFFF, (rb >> 16) & 0xFFF))
        wx, wy = r.get("WIN_X"), r.get("WIN_Y")
        x0w, x1w, y0w, y1w = wx & 0xFFFF, wx >> 16, wy & 0xFFFF, wy >> 16
        self.full_win = x0w == 0 and y0w == 0 and x1w >= w - 1 and y1w >= h - 1
        runs = []
        for t, (obj, lo, hi) in enumerate(terms):
            runs += term_runs(obj, lo, hi, t)
        runs.sort()
        res = dict(n=0, x0=0xFFFF, x1=0, y0=0xFFFF, y1=0, sx=0, sy=0, lost=0)
        cfg = r.get("BLOB_CFG")
        gap, gap_y, keep = cfg & 0xFF, (cfg >> 8) & 0xFF, cfg >> 16
        slots = [None] * NBLOB
        half = NBLOB // 2 if len(terms) > 1 else NBLOB
        for yy, _, term, ra, rb_ in runs:
            if not y0w <= yy <= y1w:
                continue
            a0, b0 = max(ra, x0w), min(rb_, x1w)                    # the run's pixels inside the window
            if a0 > b0:
                continue
            ln = b0 - a0 + 1
            res["n"] += ln
            res["x0"], res["x1"] = min(res["x0"], a0), max(res["x1"], b0)
            res["y0"], res["y1"] = min(res["y0"], yy), max(res["y1"], yy)
            res["sx"] += (a0 + b0) * ln // 2
            res["sy"] += yy * ln
            lo, hi = (0, half) if term == 0 else (half, NBLOB)
            hit = [i for i in range(lo, hi) if slots[i] is not None and a0 <= slots[i][1] + gap and
                   b0 + gap >= slots[i][0] and yy <= slots[i][3] + gap_y + 1]
            if hit:
                t = slots[hit[0]]
                t[0], t[1], t[3], t[4] = min(t[0], a0), max(t[1], b0), yy, t[4] + ln
                for i in hit[1:]:
                    o = slots[i]
                    t[0], t[1], t[2], t[4] = min(t[0], o[0]), max(t[1], o[1]), min(t[2], o[2]), t[4] + o[4]
                    slots[i] = None
                continue
            free = [i for i in range(lo, hi) if slots[i] is None or (yy > slots[i][3] + gap_y + 1 and slots[i][4] < keep)]
            if free:
                slots[free[0]] = [a0, b0, yy, yy, ln]
            else:
                res["lost"] += 1
        self.blobs = [tuple(s) if s is not None and s[4] >= keep else (0, 0, 0, 0, 0) for s in slots]
        self.res = res
        self.frames += 1

    def sts(self, name, i):
        res = self.res
        if name == "FRAMES":
            return self.frames
        if name == "COUNT":
            return res["n"]
        if name == "BOX_X":
            return (res["x1"] << 16) | (res["x0"] & 0xFFFF)
        if name == "BOX_Y":
            return (res["y1"] << 16) | (res["y0"] & 0xFFFF)
        if name == "SUM_X":
            return res["sx"] & 0xFFFFFFFF
        if name == "SUM_Y":
            return res["sy"] & 0xFFFFFFFF
        if name == "STATUS":
            return (min(res["lost"], 255) << 8) | (int(self.full_win) << 1) | ((self.frames & 0xFFFF) << 16)
        b = self.blobs[i]
        if name == "BLOB_X":
            return (b[1] << 16) | b[0] if b[4] else 0
        if name == "BLOB_Y":
            return (b[3] << 16) | b[2] if b[4] else 0
        if name == "BLOB_N":
            return b[4]
        return 0
