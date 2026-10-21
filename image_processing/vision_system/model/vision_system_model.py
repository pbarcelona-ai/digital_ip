"""vision_system model (Python model of image_processing/vision_system/src/vision_system.sv), frame exact: its
register block (vision_system_regs.json) and the lens / geometry correction of a frame, in the RTL's fixed point.

  BYPASS[0]  the frame passes unchanged (switched between frames).
  Frame size (frame_size): IMG_WIDTH / IMG_HEIGHT clamped into 1..MAX_W / 1..MAX_H.
  Calibration (axi_lite_regs): CALIB_MODE 0 derives the pinhole intrinsics from the frame size, CENTER and SCALE -
    W = width << 16, cx = qmul(CENTER_X, W), fx = qmul(qmul(W, 0.5), SCALE) (likewise y); CALIB_MODE 1 takes
    FX / FY / CX / CY directly; recip_fx / recip_fy = fixed_recip(fx / fy) (the RTL's iterative divider, after a
    geometry register write). Every product is barrel_pkg's saturating qmul; the products here are not summed.
  Per output pixel (x, y): (sx, sy) = coord_gen(cfg, x, y) (Q16.16, every model of MODEL_SEL), then
    bilinear (INTERP_MODE 0): x0 = sx >> 16, taps x0 / x0 + 1 and y0 / y0 + 1 each clamped to the frame
      (edge replication), fractions sx[15:8] / sy[15:8], bilinear.sv's arithmetic;
    bicubic (INTERP_MODE 1): taps x0 - 1 .. x0 + 2 / y0 - 1 .. y0 + 2 each clamped to the frame, fractions
      sx[15:0] / sy[15:0], bicubic.sv's arithmetic.
  STATUS [0] busy [1] frame done (write 1 to clear; set when a corrected frame has left) [2] reciprocal busy.
Frames are IMG_WIDTH x IMG_HEIGHT RGB888 ({B, G, R}, R in the LSBs). run() also keeps the float reference of the
original model (reference_float) for comparisons of the correction itself."""
import numpy as np

from barrel_pkg_model import MAX_H, MAX_W, qmul, s32
from bicubic_model import bicubic
from bilinear_model import bilinear
from coord_gen_model import CalibParams, coord_gen
from fixed_recip_model import recip
from pixel import signed
from regs import RegMap, ip_regs


def frame_size(r):
    """The frame size (width, height): IMG_WIDTH / IMG_HEIGHT clamped into 1..MAX_W / 1..MAX_H (axi_lite_regs)."""
    return (min(max(r.get("IMG_WIDTH"), 1), MAX_W), min(max(r.get("IMG_HEIGHT"), 1), MAX_H))


def calibration(r):
    """calib_params_t from the register map r (axi_lite_regs.sv)."""
    g = r.get
    w, h = frame_size(r)
    w_q, h_q = s32(w << 16), s32(h << 16)
    if g("CALIB_MODE") & 1:
        cx, cy, fx, fy = (s32(g(n)) for n in ("CX", "CY", "FX", "FY"))
    else:
        cx, cy = qmul(s32(g("CENTER_X")), w_q), qmul(s32(g("CENTER_Y")), h_q)
        fx = qmul(qmul(w_q, 0x8000), s32(g("SCALE")))
        fy = qmul(qmul(h_q, 0x8000), s32(g("SCALE")))
    c = CalibParams(cx_pix=cx, cy_pix=cy, fx_pix=fx, fy_pix=fy, recip_fx=recip(fx & 0xFFFFFFFF),
                    recip_fy=recip(fy & 0xFFFFFFFF), model_sel=g("MODEL_SEL") & 7)
    for n in ("k1", "k2", "k3", "p1", "p2", "h11", "h12", "h13", "h21", "h22", "h23", "h31", "h32"):
        setattr(c, n, s32(g(n.upper())))
    return c


def _clamp(v, n):
    return 0 if v < 0 else n - 1 if v > n - 1 else v


def correct(px, w, h, c, interp):
    """The corrected frame (list of rows of 24-bit pixels) of px (rows of 24-bit pixels) under calibration c."""
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            sx, sy = coord_gen(c, x, y)
            x0, y0 = sx >> 16, sy >> 16
            if interp:
                taps = [[px[_clamp(y0 - 1 + i, h)][_clamp(x0 - 1 + j, w)] for j in range(4)] for i in range(4)]
                row.append(bicubic(sx & 0xFFFF, sy & 0xFFFF, taps))
            else:
                xa, xb, ya, yb = _clamp(x0, w), _clamp(x0 + 1, w), _clamp(y0, h), _clamp(y0 + 1, h)
                row.append(bilinear((sx >> 8) & 0xFF, (sy >> 8) & 0xFF, px[ya][xa], px[ya][xb], px[yb][xa],
                                    px[yb][xb]))
        out.append(row)
    return out


def pack(rgb):
    """h x w x 3 (R, G, B) -> rows of 24-bit pixels."""
    a = np.asarray(rgb, np.int64)
    return (a[..., 0] | a[..., 1] << 8 | a[..., 2] << 16).tolist()


def unpack(rows):
    a = np.array(rows, np.int64)
    return np.stack([a & 255, (a >> 8) & 255, (a >> 16) & 255], -1).astype(np.uint8)


class VisionSystem:
    """vision_system: registers, STATUS, run(frame) the correction (or the frame unchanged with BYPASS)."""

    def __init__(self):
        self.r = RegMap(ip_regs(__file__, "vision_system"))
        self.busy = False
        self.done = False
        self.r.sts = lambda n, i: (int(self.busy) | int(self.done) << 1) if n == "STATUS" else 0
        self.r.on_write = self._w

    def _w(self, n, i, d):
        if n == "STATUS" and d & 2:
            self.done = False

    def run(self, rgb):
        """One frame (h x w x 3 uint8 of frame_size(r)): the output frame."""
        if self.r.get("BYPASS") & 1:
            return rgb
        h, w = rgb.shape[:2]
        out = unpack(correct(pack(rgb), w, h, calibration(self.r), self.r.get("INTERP_MODE") & 1))
        self.done = True
        return out

    def reference_float(self, rgb):
        """The floating-point radial correction of the original model (for comparisons only)."""
        vs = self.r
        k = [signed(vs.get(n), 32) / 65536.0 for n in ("K1", "K2", "K3")]
        scale = vs.get("SCALE") / 65536.0
        h, w = rgb.shape[:2]
        cx, cy = vs.get("CENTER_X") / 65536.0 * w, vs.get("CENTER_Y") / 65536.0 * h
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
        nx, ny = (xx - cx) / (w / 2.0) / scale, (yy - cy) / (h / 2.0) / scale
        r2 = nx * nx + ny * ny
        f = 1 + k[0] * r2 + k[1] * r2 * r2 + k[2] * r2 ** 3
        sx, sy = cx + nx * f * (w / 2.0), cy + ny * f * (h / 2.0)
        x0, y0 = np.clip(np.floor(sx).astype(int), 0, w - 1), np.clip(np.floor(sy).astype(int), 0, h - 1)
        x1, y1 = np.clip(x0 + 1, 0, w - 1), np.clip(y0 + 1, 0, h - 1)
        fx, fy = np.clip(sx - x0, 0, 1)[..., None], np.clip(sy - y0, 0, 1)[..., None]
        p = rgb.astype(np.float64)
        o = (p[y0, x0] * (1 - fx) * (1 - fy) + p[y0, x1] * fx * (1 - fy) + p[y1, x0] * (1 - fx) * fy
             + p[y1, x1] * fx * fy)
        return np.clip(np.round(o), 0, 255).astype(np.uint8)
