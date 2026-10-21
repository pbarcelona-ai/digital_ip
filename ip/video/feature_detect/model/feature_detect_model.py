"""feature_detect model (Python model of ip/video/feature_detect/src/feature_detect_top.sv), frame exact: the
feature bits of every pixel (the RTL gives them with each beat it forwards) and the registers after each frame,
as in python-prototype/detect_proto.py.

A frame is processed when CTRL.EN is set at its start; the configuration (CTRL, EDGE, MOTION, SHIFT, SKY_CFG) is
taken at the frame start. FRAME_SIZE must be the frame's size (the RTL finds the frame end and the cells with it).
  luma    Y = (R + 2 G + B) >> 2;
  edge    Sobel |Gx| + |Gy| of the 3 x 3 window ending at the pixel (rows y - 2 .. y, columns x - 2 .. x) above
          EDGE.THRESH (x, y >= 2), with CTRL.EDGE_EN; filled along the line: set when an edge was found in the
          last EDGE.SPAN pixels (0 or 1: the pixel itself);
  motion  cells of 2**cell_log2 pixels square (cw = width >> cell_log2 by ch = height >> cell_log2; pixels past
          them never move); per cell the lowest and highest luma x 16 of each frame; the background lo / hi of
          the cell the pixel came from, (cx - sx, cy - sy) with the frame's shift, when it is in the frame: the
          pixel moves when below lo / 16 - MOTION.THRESH or above hi / 16 + MOTION.THRESH (CTRL.MOTION_EN),
          filled with MOTION.SPAN; after the frame each cell becomes old + (new - old) >> MOTION.RATE of its
          source (floor), or the new values without a valid source; the first frame after a restart only fills
          the background;
  shift   the column / row luma profiles (sums per cell column / cell row over the cells); after a frame with a
          previous one, per axis the shift s in -shift_max .. shift_max with the lowest sum over i = shift_max
          .. n - 1 - shift_max of |cur[i] - prev[i - s]| (0 first, a later s only when strictly lower; n <
          2 shift_max + 1: 0) -> SHIFT_EST; with CTRL.AUTO_SHIFT a frame uses the estimate of the search that
          ended two frames before it (the search after frame N runs during frame N + 1, frame N + 2 uses it),
          else SHIFT;
  sky     per column group of 2**SKY_CFG.SHIFT pixels (at most 32 groups), the lines from the top down to the
          group's first pixel with the (filled) edge bit or a luma below SKY_CFG.Y_MIN (the frame height when
          none) -> SKY[0..31].
A restart (a CTRL write with RESTART, or a FRAME_SIZE write) acts at the next frame start: background, profiles
and shift start again. Registers after a frame: FRAMES, EDGE_COUNT, MOTION_COUNT, SHIFT_EST, SHIFT_USED, SKY,
STATUS [1] BG_VALID [31:16] FRAMES ([0] IN_FRAME and [2] BUSY read 0 between frames once the search is done)."""
import numpy as np

from pixel import fill, luma
from regs import RegMap, ip_regs


class FeatureDetect:
    """feature_detect: edge and motion bits of every pixel of a frame (step), the sky profile and the camera
    shift."""

    def __init__(self, cell_log2=2, shift_max=4):
        self.CELL, self.SHIFT_MAX = 1 << cell_log2, shift_max
        self.r = RegMap(ip_regs(__file__, "feature_detect"))
        self.r.sts = self._sts
        self.r.on_write = self._w
        self.restart_pend = False
        self.reset_bg()
        self.frames = 0
        self.n_edge = self.n_mot = 0
        self.shift_used = (0, 0)
        self.sky = [0] * 32

    def _w(self, name, i, d):
        if (name == "CTRL" and d & 16) or name == "FRAME_SIZE":
            self.restart_pend = True

    def reset_bg(self):
        self.lo = self.hi = None
        self.prev_col = self.prev_row = None
        self.shift_est = (0, 0)                          # the last search's result
        self.shift_next = (0, 0)                         # the estimate the next frame uses (AUTO_SHIFT)

    def best_shift(self, cur, prev):
        n, sm = len(cur), self.SHIFT_MAX

        def sad(s):
            return int(sum(abs(int(cur[i]) - int(prev[i - s])) for i in range(sm, n - sm)))
        if n < 2 * sm + 1:
            return 0
        best, bs = sad(0), 0
        for s in range(-sm, sm + 1):
            d = sad(s)
            if d < best:
                best, bs = d, s
        return bs

    def step(self, rgb):
        """Feature bits (edge, motion) of a frame; updates the background, the shift and the registers."""
        r = self.r
        ctrl = r.get("CTRL")
        y = luma(rgb)
        h, w = y.shape
        e = np.zeros((h, w), bool)
        m = np.zeros((h, w), bool)
        if not ctrl & 1:
            return e, m
        if self.restart_pend:
            self.reset_bg()
            self.restart_pend = False
        if ctrl & 2:
            ed = r.get("EDGE")
            thr, span = ed & 0x7FF, (ed >> 16) & 15
            gx = (y[:-2, 2:] + 2 * y[1:-1, 2:] + y[2:, 2:]) - (y[:-2, :-2] + 2 * y[1:-1, :-2] + y[2:, :-2])
            gy = (y[2:, :-2] + 2 * y[2:, 1:-1] + y[2:, 2:]) - (y[:-2, :-2] + 2 * y[:-2, 1:-1] + y[:-2, 2:])
            e[2:, 2:] = (np.abs(gx) + np.abs(gy)) > thr
            e = fill(e, span)
        sc = r.get("SKY_CFG")
        gs = 1 << (sc & 15)
        ns = e | (y < ((sc >> 8) & 0xFF))
        first = np.where(ns.any(0), ns.argmax(0), h)
        self.sky = [int(first[g * gs:(g + 1) * gs].min()) if g * gs < w else h for g in range(32)]
        mo = r.get("MOTION")
        mthr, mspan, rate = mo & 0xFF, (mo >> 8) & 15, (mo >> 12) & 7
        C = self.CELL
        ch, cw = h // C, w // C
        yc = y[:ch * C, :cw * C]
        blk = yc.reshape(ch, C, cw, C)
        cmin, cmax = blk.min(axis=(1, 3)) << 4, blk.max(axis=(1, 3)) << 4
        col = yc.sum(axis=0).reshape(cw, C).sum(axis=1)
        row = yc.sum(axis=1).reshape(ch, C).sum(axis=1)
        sx, sy = self.shift_next if ctrl & 8 else self._manual_shift()
        self.shift_used = (sx, sy)
        if self.lo is not None and self.lo.shape == cmin.shape:
            lo, ok = self._src(self.lo, sy, sx)
            hi, _ = self._src(self.hi, sy, sx)
            if ctrl & 4:
                lo_p = np.repeat(np.repeat(lo >> 4, C, 0), C, 1)
                hi_p = np.repeat(np.repeat(hi >> 4, C, 0), C, 1)
                ok_p = np.repeat(np.repeat(ok, C, 0), C, 1)
                m[:ch * C, :cw * C] = ok_p & ((yc < lo_p - mthr) | (yc > hi_p + mthr))
                m = fill(m, mspan)
            self.lo = np.where(ok, lo + ((cmin - lo) >> rate), cmin)
            self.hi = np.where(ok, hi + ((cmax - hi) >> rate), cmax)
        else:
            self.lo, self.hi = cmin, cmax
        self.shift_next = self.shift_est                 # the search of the frame before: for the next frame
        if self.prev_col is not None and len(self.prev_col) == len(col):
            self.shift_est = (self.best_shift(col, self.prev_col), self.best_shift(row, self.prev_row))
        self.prev_col, self.prev_row = col, row
        self.frames += 1
        self.n_edge, self.n_mot = int(e.sum()), int(m.sum())
        return e, m

    def _manual_shift(self):
        v = self.r.get("SHIFT")
        sx, sy = v & 0xFF, (v >> 8) & 0xFF
        return (sx - 256 if sx & 0x80 else sx), (sy - 256 if sy & 0x80 else sy)

    def _src(self, a, sy, sx):
        out = np.zeros_like(a)
        ok = np.zeros(a.shape, bool)
        ch, cw = a.shape
        ys, ye = max(0, sy), ch + min(0, sy)
        xs, xe = max(0, sx), cw + min(0, sx)
        if ye > ys and xe > xs:
            out[ys:ye, xs:xe] = a[ys - sy:ye - sy, xs - sx:xe - sx]
            ok[ys:ye, xs:xe] = True
        return out, ok

    def _sts(self, n, i):
        if n == "SHIFT_EST":
            return (self.shift_est[0] & 0xFF) | ((self.shift_est[1] & 0xFF) << 8)
        if n == "SHIFT_USED":
            return (self.shift_used[0] & 0xFF) | ((self.shift_used[1] & 0xFF) << 8)
        if n == "STATUS":
            return (int(self.lo is not None) << 1) | ((self.frames & 0xFFFF) << 16)
        if n == "SKY":
            return self.sky[i]
        return {"FRAMES": self.frames, "EDGE_COUNT": self.n_edge, "MOTION_COUNT": self.n_mot}.get(n, 0)
