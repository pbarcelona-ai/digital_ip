"""coord_gen model (Python model of image_processing/vision_system/ip/coord_gen/src/coord_gen.sv), bit and clock
exact: the Q16.16 source coordinate (sx, sy) of output pixel (x, y) for the calibration cfg (CalibParams; all
fields signed 32-bit Q16.16 except recip_fx / recip_fy, unsigned, read as signed by the multiplies).
Every product is barrel_pkg's saturating qmul, every sum is exact and then saturated to signed 32 bits
(barrel_pkg's sat40; a doubling is part of the exact sum):
  dx = (x << 16) - cx, dy = (y << 16) - cy, nx = qmul(dx, recip_fx), ny = qmul(dy, recip_fy)
  fast path (RADIAL, and AFFINE / SCALING / reserved codes with the distortion terms zero), LATENCY 23, one
  request per clock:
    r2 = nx^2 + ny^2, r4 = r2^2, r6 = r4 r2 (each square a qmul)
    RADIAL: t1 = qmul(k1, r2), t2 = qmul(k2, r4), t3 = qmul(k3, r6),
            tx = 2 qmul(p1, nx ny) + qmul(p2, r2 + 2 nx^2), ty = qmul(p1, r2 + 2 ny^2) + 2 qmul(p2, nx ny)
    others: t1 = t2 = t3 = tx = ty = 0
    factor = 1 + t1 + t2 + t3; sx = cx + qmul(qmul(nx, factor) + tx, fx); sy likewise with ny, ty, fy
  slow path (FISHEYE, PANORAMIC, PERSPECTIVE), one request at a time, result SLOW_LATENCY clocks after it,
  busy from the clock after the request until the result:
    denominator FISHEYE 1 + qmul(k1, r2) + qmul(k2, r4); PANORAMIC 1 + qmul(k1, nx^2); PERSPECTIVE
    1 + qmul(h31, x << 16) + qmul(h32, y << 16); a value <= 0 becomes 1 (one LSB); rec = fixed_recip(it)
    PERSPECTIVE: sx = qmul(qmul(h11, X) + qmul(h12, Y) + h13, rec), sy = qmul(qmul(h21, X) + qmul(h22, Y) + h23,
    rec) with X, Y = x << 16, y << 16; FISHEYE: sx = cx + qmul(qmul(nx, rec), fx), sy = cy + qmul(qmul(ny, rec),
    fy); PANORAMIC: sx as FISHEYE, sy = cy + qmul(ny, fy)."""
from dataclasses import dataclass

from barrel_pkg_model import qmul, qsat48 as sat, s32
from fixed_recip_model import done_edge, recip

RADIAL, FISHEYE, AFFINE, PERSPECTIVE, SCALING, PANORAMIC = range(6)
SLOW = (FISHEYE, PANORAMIC, PERSPECTIVE)
LATENCY = 23                                         # fast path: request edge to out_valid
SD_PRE_CYCLES, SD_POST_CYCLES = 16, 8
# slow path: request (edge 0) -> PRE (16 edges) -> ISSUE -> fixed_recip start .. done -> POST (8) -> DONE
SLOW_LATENCY = SD_PRE_CYCLES + 2 + done_edge() + 1 + SD_POST_CYCLES + 1


@dataclass
class CalibParams:
    """calib_params_t (distortion_model_pkg)."""
    cx_pix: int = 0
    cy_pix: int = 0
    fx_pix: int = 1 << 16
    fy_pix: int = 1 << 16
    recip_fx: int = 1 << 16
    recip_fy: int = 1 << 16
    k1: int = 0
    k2: int = 0
    k3: int = 0
    p1: int = 0
    p2: int = 0
    h11: int = 1 << 16
    h12: int = 0
    h13: int = 0
    h21: int = 0
    h22: int = 1 << 16
    h23: int = 0
    h31: int = 0
    h32: int = 0
    model_sel: int = RADIAL


def coord_gen(c, x, y):
    """(sx, sy) signed Q16.16 for output pixel (x, y) under calibration c."""
    rfx, rfy = s32(c.recip_fx), s32(c.recip_fy)
    xq, yq = x << 16, y << 16
    nx, ny = qmul(sat(xq - c.cx_pix), rfx), qmul(sat(yq - c.cy_pix), rfy)
    nxsq, nysq = qmul(nx, nx), qmul(ny, ny)
    r2 = sat(nxsq + nysq)
    r4 = qmul(r2, r2)
    if c.model_sel not in SLOW:
        r6 = qmul(r4, r2)
        nxny = qmul(nx, ny)
        if c.model_sel == RADIAL:
            t = qmul(c.k1, r2) + qmul(c.k2, r4) + qmul(c.k3, r6)
            tx = sat(2 * qmul(c.p1, nxny) + qmul(c.p2, sat(r2 + 2 * nxsq)))
            ty = sat(qmul(c.p1, sat(r2 + 2 * nysq)) + 2 * qmul(c.p2, nxny))
        else:
            t = tx = ty = 0
        factor = sat((1 << 16) + t)
        sxn, syn = sat(qmul(nx, factor) + tx), sat(qmul(ny, factor) + ty)
        return sat(c.cx_pix + qmul(sxn, c.fx_pix)), sat(c.cy_pix + qmul(syn, c.fy_pix))
    if c.model_sel == FISHEYE:
        raw = sat((1 << 16) + qmul(c.k1, r2) + qmul(c.k2, r4))
    elif c.model_sel == PANORAMIC:
        raw = sat((1 << 16) + qmul(c.k1, nxsq))
    else:
        raw = sat((1 << 16) + qmul(c.h31, xq) + qmul(c.h32, yq))
    rec = s32(recip((raw if raw > 0 else 1) & 0xFFFFFFFF))
    if c.model_sel == PERSPECTIVE:
        numx = sat(qmul(c.h11, xq) + qmul(c.h12, yq) + c.h13)
        numy = sat(qmul(c.h21, xq) + qmul(c.h22, yq) + c.h23)
        return qmul(numx, rec), qmul(numy, rec)
    sx = sat(c.cx_pix + qmul(qmul(nx, rec), c.fx_pix))
    if c.model_sel == PANORAMIC:
        return sx, sat(c.cy_pix + qmul(ny, c.fy_pix))
    return sx, sat(c.cy_pix + qmul(qmul(ny, rec), c.fy_pix))
