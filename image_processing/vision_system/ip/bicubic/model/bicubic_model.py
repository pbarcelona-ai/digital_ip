"""bicubic model (Python model of image_processing/vision_system/ip/bicubic/src/bicubic.sv), bit and clock exact:
separable Catmull-Rom (a = -0.5) interpolation of RGB888 over 4 x 4 taps p[row][col] (row / col 0 = y0 - 1 /
x0 - 1 .. 3 = y0 + 2 / x0 + 2) with Q16.16 fractions tx, ty (the ports' 32 bits read as signed):
  weights (each product a saturating qmul, sums in 32 bits):
    w0 = qmul(-0.5, t^3) + t^2 - qmul(0.5, t)      w1 = qmul(1.5, t^3) - qmul(2.5, t^2) + 1
    w2 = qmul(-1.5, t^3) + qmul(2, t^2) + qmul(0.5, t)   w3 = qmul(0.5, t^3) - qmul(0.5, t^2)
    with t^2 = qmul(t, t), t^3 = qmul(t^2, t);
  row[r] = sum_c p[r][c] * wx[c]   (8-bit pixel x Q16.16 weight, exact, summed in 40 bits);
  fin = sum_r qmul(row[r] truncated to signed 32 bits, wy[r])   (32-bit sums);
  out = clamp(((fin + 32768) in 32 bits) >>> 16, 0, 255) per channel ([23:16], [15:8], [7:0]).
LATENCY 18 clocks from valid_in to valid_out; one set of taps per clock is accepted (no back-pressure)."""
from barrel_pkg_model import qmul, s32, s40

LATENCY = 18


def weights(t):
    """The four Catmull-Rom weights (signed Q16.16) of the fraction t."""
    t2 = qmul(t, t)
    t3 = qmul(t2, t)
    return (s32(qmul(-32768, t3) + t2 - qmul(32768, t)),
            s32(qmul(98304, t3) - qmul(163840, t2) + 65536),
            s32(qmul(-98304, t3) + qmul(131072, t2) + qmul(32768, t)),
            s32(qmul(32768, t3) - qmul(32768, t2)))


def _chan(v):
    v = s32(v + 32768) >> 16
    return 0 if v < 0 else 255 if v > 255 else v


def bicubic(tx, ty, taps):
    """The output pixel for unsigned 32-bit tx, ty and taps[row][col] (24-bit pixels)."""
    wx, wy = weights(s32(tx)), weights(s32(ty))
    out = 0
    for sh in (16, 8, 0):
        rows = []
        for r in range(4):
            q = [((taps[r][c] >> sh) & 0xFF) * wx[c] for c in range(4)]
            rows.append(s40(s40(q[0] + q[1]) + s40(q[2] + q[3])))
        m = [qmul(s32(rows[r]), wy[r]) for r in range(4)]
        out |= _chan(s32(s32(m[0] + m[1]) + s32(m[2] + m[3]))) << sh
    return out
