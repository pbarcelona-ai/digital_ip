"""
image_io.py

- Loads test.jpg / test.ppm (generates a synthetic test chart if neither
  exists).
- A bit-exact Python model of the RTL fixed-point datapath (same Q16.16
  format, same qmul() truncation/saturation, same reciprocal divider,
  same bilinear rounding) used to:
    1) synthesize warped.jpg/.ppm from the original test image, and
    2) act as the golden reference that the DUT's corrected.jpg/.ppm
       output is checked against.

Because (1) and (2) use the exact same primitive the hardware implements,
the self-check is meaningful: the DUT is checked bit-for-bit (within a
small tolerance for legitimate alternate-but-equally-valid rounding)
against a reference model of its own algorithm, and separately checked
for genuine image-quality improvement (corrected image much closer to
the original than the warped image was).
"""
import os
import numpy as np
from PIL import Image

FRAC_BITS = 16
ONE_Q16 = 1 << 16
I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1

SIM_MAX_DIM = 160  # keep RTL simulation runtime reasonable


def to_q16(x: float) -> int:
    return int(round(x * 65536.0))


def from_q16(x: int) -> float:
    return x / 65536.0


def qmul(a: int, b: int) -> int:
    """Exactly mirrors barrel_pkg::qmul: 32x32->64 signed multiply,
    arithmetic shift right by FRAC_BITS, saturate to signed 32-bit."""
    prod = (a * b) >> FRAC_BITS   # Python >> on ints is arithmetic (floor) -- matches >>>
    if prod > I32_MAX:
        return I32_MAX
    if prod < I32_MIN:
        return I32_MIN
    return prod


def bits(v: int, hi: int, lo: int) -> int:
    """Mirrors a Verilog part-select v[hi:lo] on the two's-complement
    bit pattern of a (possibly negative) 32-bit value."""
    uv = v & 0xFFFFFFFF
    width = hi - lo + 1
    return (uv >> lo) & ((1 << width) - 1)


def fixed_recip(operand: int) -> int:
    """Mirrors fixed_recip.sv: floor(2^32 / operand), operand treated as
    unsigned Q16.16 > 0 (0 guarded to 1), saturating on overflow."""
    if operand <= 0:
        operand = 1
    q = (1 << 32) // operand
    if q > 0xFFFFFFFF:
        q = 0xFFFFFFFF
    return q


def coord_gen_ref(cx_pix: int, cy_pix: int, fx_pix: int, fy_pix: int,
                   k1: int, k2: int, k3: int, p1: int, p2: int,
                   model_sel: int, x: int, y: int,
                   h11: int = 0, h12: int = 0, h13: int = 0,
                   h21: int = 0, h22: int = 0, h23: int = 0,
                   h31: int = 0, h32: int = 0):
    """Independent reference for coord_gen.sv's per-pixel math, INCLUDING
    the camera-calibration-style direct fx/fy/cx/cy parameterization,
    tangential ("plumb bob") distortion, the REAL fisheye/panoramic
    (division-model) and perspective (homography) implementations, and
    the model_sel hook gate for the two still-unimplemented models
    (MODEL_AFFINE/MODEL_SCALING). model_sel is distortion_model_e's raw
    encoding: 0=RADIAL,1=FISHEYE,2=AFFINE,3=PERSPECTIVE,4=SCALING,
    5=PANORAMIC (matching distortion_model_pkg.sv). Written from scratch
    here (not calling the SystemVerilog golden model or the RTL) per this
    project's verification philosophy -- see golden_model_pkg.sv's
    coord_gen_ref for the SystemVerilog counterpart.
    Returns (sx, sy) in signed Q16.16."""
    recip_fx = fixed_recip(fx_pix)
    recip_fy = fixed_recip(fy_pix)
    dx = (x << 16) - cx_pix
    dy = (y << 16) - cy_pix
    nx = qmul(dx, recip_fx)
    ny = qmul(dy, recip_fy)
    r2 = qmul(nx, nx) + qmul(ny, ny)

    if model_sel == 0:  # MODEL_RADIAL
        r4 = qmul(r2, r2)
        r6 = qmul(r4, r2)
        t1 = qmul(k1, r2)
        t2 = qmul(k2, r4)
        t3 = qmul(k3, r6)
        factor = ONE_Q16 + t1 + t2 + t3
        tangx = (qmul(p1, qmul(nx, ny)) << 1) + qmul(p2, r2 + (qmul(nx, nx) << 1))
        tangy = qmul(p1, r2 + (qmul(ny, ny) << 1)) + (qmul(p2, qmul(nx, ny)) << 1)
        sxn = qmul(nx, factor) + tangx
        syn = qmul(ny, factor) + tangy
        sx = cx_pix + qmul(sxn, fx_pix)
        sy = cy_pix + qmul(syn, fy_pix)
    elif model_sel == 1:  # MODEL_FISHEYE (division model)
        r4 = qmul(r2, r2)
        denom_raw = ONE_Q16 + qmul(k1, r2) + qmul(k2, r4)
        denom_safe = denom_raw if denom_raw > 0 else 1
        recip_denom = fixed_recip(denom_safe)
        sx = cx_pix + qmul(qmul(nx, recip_denom), fx_pix)
        sy = cy_pix + qmul(qmul(ny, recip_denom), fy_pix)
    elif model_sel == 5:  # MODEL_PANORAMIC (division model, x only)
        denom_raw = ONE_Q16 + qmul(k1, qmul(nx, nx))
        denom_safe = denom_raw if denom_raw > 0 else 1
        recip_denom = fixed_recip(denom_safe)
        sx = cx_pix + qmul(qmul(nx, recip_denom), fx_pix)
        sy = cy_pix + qmul(ny, fy_pix)
    elif model_sel == 3:  # MODEL_PERSPECTIVE (homography)
        xq = x << 16
        yq = y << 16
        denom_raw = ONE_Q16 + qmul(h31, xq) + qmul(h32, yq)
        denom_safe = denom_raw if denom_raw > 0 else 1
        recip_denom = fixed_recip(denom_safe)
        num_x = qmul(h11, xq) + qmul(h12, yq) + h13
        num_y = qmul(h21, xq) + qmul(h22, yq) + h23
        sx = qmul(num_x, recip_denom)
        sy = qmul(num_y, recip_denom)
    else:  # MODEL_AFFINE / MODEL_SCALING: reserved hooks, identity
        sx = cx_pix + qmul(nx, fx_pix)
        sy = cy_pix + qmul(ny, fy_pix)
    return sx, sy


def full_remap_ref(cfg: "RemapConfig", model_sel: int,
                    k1: int, k2: int, k3: int, p1: int, p2: int,
                    h11: int, h12: int, h13: int, h21: int, h22: int, h23: int,
                    h31: int, h32: int, src: np.ndarray) -> np.ndarray:
    """Full-image counterpart of coord_gen_ref: calls it per-pixel
    (reusing that single already cross-checked implementation rather than
    duplicating the per-model math again) and bilinear-samples the
    result. Used both to synthesize fisheye/panoramic/perspective-
    distorted test images (forward warp) and to compute the golden
    corrected reference for the image-level correction tests."""
    w, h = cfg.w, cfg.h
    out = np.zeros((h, w, 3), dtype=np.uint8)
    src_i = src.astype(np.int64)

    for y in range(h):
        for x in range(w):
            sx, sy = coord_gen_ref(cfg.cx_pix, cfg.cy_pix, cfg.halfw_scaled, cfg.halfh_scaled,
                                    k1, k2, k3, p1, p2, model_sel, x, y,
                                    h11, h12, h13, h21, h22, h23, h31, h32)
            if sx < 0:
                x0 = 0
                fx = 0
            else:
                x0s = sx >> FRAC_BITS
                if x0s > (w - 2):
                    x0 = w - 2
                    fx = 255
                else:
                    x0 = x0s
                    fx = bits(sx, 15, 8)
            if sy < 0:
                y0 = 0
                fy = 0
            else:
                y0s = sy >> FRAC_BITS
                if y0s > (h - 2):
                    y0 = h - 2
                    fy = 255
                else:
                    y0 = y0s
                    fy = bits(sy, 15, 8)

            tl = src_i[y0, x0]
            tr = src_i[y0, x0 + 1]
            bl = src_i[y0 + 1, x0]
            br = src_i[y0 + 1, x0 + 1]

            w00 = (256 - fx) * (256 - fy)
            w10 = fx * (256 - fy)
            w01 = (256 - fx) * fy
            w11 = fx * fy

            acc = tl * w00 + tr * w10 + bl * w01 + br * w11
            acc = acc + 32768
            out[y, x] = np.clip(acc >> 16, 0, 255)

    return out


def fit_division_model_coeffs(cfg: "RemapConfig", model_sel: int,
                               warp: np.ndarray, orig: np.ndarray):
    """Simple grid search for the division-model (fisheye/panoramic)
    correction coefficient(s): tries a spread of candidate kc1 (and, for
    fisheye, kc2) values, re-runs full_remap_ref, and keeps whichever
    minimizes MAE against the original. Not a closed-form fit (the
    division model isn't linear in its coefficients the way the radial
    polynomial's least-squares fit is) -- but the same underlying goal:
    find coefficients that measurably undo the synthesized distortion,
    exactly the standard this project's barrel/pincushion tests are
    already held to. Mirrors golden_model_pkg.sv's
    fit_division_model_coeffs."""
    kc1_candidates = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35]
    kc2_candidates = [0.0, -0.02, 0.02] if model_sel == 1 else [0.0]

    best_mae = float("inf")
    best_kc1, best_kc2 = 0, 0
    orig_i = orig.astype(np.int64)

    for kc1 in kc1_candidates:
        for kc2 in kc2_candidates:
            kc1_q = to_q16(kc1)
            kc2_q = to_q16(kc2)
            trial = full_remap_ref(cfg, model_sel, kc1_q, kc2_q, 0, 0, 0,
                                    0, 0, 0, 0, 0, 0, 0, 0, warp)
            mae = float(np.abs(trial.astype(np.int64) - orig_i).mean())
            if mae < best_mae:
                best_mae = mae
                best_kc1, best_kc2 = kc1_q, kc2_q

    return best_kc1, best_kc2


def invert_homography(h11: float, h12: float, h13: float,
                       h21: float, h22: float, h23: float,
                       h31: float, h32: float):
    """Closed-form 3x3 matrix inverse (cofactor/adjugate method), for
    finding the CORRECTING homography given the (known, since we chose
    it to synthesize the test image) forward-distorting one -- an exact
    inverse, unlike the approximate/fitted corrections the division-model
    functions above use, because a homography's exact inverse is both
    well-defined and easy to compute in closed form. Mirrors
    golden_model_pkg.sv's invert_homography."""
    h33 = 1.0
    a = [[h11, h12, h13], [h21, h22, h23], [h31, h32, h33]]

    det = (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
           - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
           + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    if det == 0.0:
        det = 1.0e-9

    adj = [[0.0] * 3 for _ in range(3)]
    adj[0][0] = (a[1][1] * a[2][2] - a[1][2] * a[2][1])
    adj[0][1] = -(a[0][1] * a[2][2] - a[0][2] * a[2][1])
    adj[0][2] = (a[0][1] * a[1][2] - a[0][2] * a[1][1])
    adj[1][0] = -(a[1][0] * a[2][2] - a[1][2] * a[2][0])
    adj[1][1] = (a[0][0] * a[2][2] - a[0][2] * a[2][0])
    adj[1][2] = -(a[0][0] * a[1][2] - a[0][2] * a[1][0])
    adj[2][0] = (a[1][0] * a[2][1] - a[1][1] * a[2][0])
    adj[2][1] = -(a[0][0] * a[2][1] - a[0][1] * a[2][0])
    adj[2][2] = (a[0][0] * a[1][1] - a[0][1] * a[1][0])

    scale = (adj[2][2] / det)
    i11, i12, i13 = adj[0][0] / det / scale, adj[0][1] / det / scale, adj[0][2] / det / scale
    i21, i22, i23 = adj[1][0] / det / scale, adj[1][1] / det / scale, adj[1][2] / det / scale
    i31, i32 = adj[2][0] / det / scale, adj[2][1] / det / scale
    return i11, i12, i13, i21, i22, i23, i31, i32


def find_or_make_test_image(directory: str) -> str:
    """Returns the path to test.jpg or test.ppm, generating a synthetic
    chart at test.ppm if neither is present."""
    for name in ("test.jpg", "test.jpeg", "test.ppm"):
        p = os.path.join(directory, name)
        if os.path.exists(p):
            return p
    path = os.path.join(directory, "test.ppm")
    make_synthetic_chart(path, 128, 96)
    return path


def make_synthetic_chart(path: str, w: int, h: int):
    """A colored grid + concentric-circle chart: straight lines and
    circles make barrel distortion (and its correction) easy to see."""
    img = np.full((h, w, 3), 250, dtype=np.uint8)
    step = max(6, w // 16)
    for x in range(0, w, step):
        img[:, x:x + 1, :] = [40, 40, 40]
    for y in range(0, h, step):
        img[y:y + 1, :, :] = [40, 40, 40]
    cx, cy = w / 2.0, h / 2.0
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    for i, ring in enumerate(range(step, int(min(w, h) * 0.6), step)):
        mask = np.abs(r - ring) < 1.0
        color = [(60 + 40 * i) % 255, (180 - 20 * i) % 255, (20 + 30 * i) % 255]
        img[mask] = color
    # colored quadrant tint so orientation/color-channel bugs are visible
    img[:h // 2, :w // 2, 0] = np.minimum(255, img[:h // 2, :w // 2, 0].astype(int) + 25)
    img[:h // 2, w // 2:, 1] = np.minimum(255, img[:h // 2, w // 2:, 1].astype(int) + 25)
    img[h // 2:, :w // 2, 2] = np.minimum(255, img[h // 2:, :w // 2, 2].astype(int) + 25)
    write_image(path, img)


def fit_correction_coeffs(kd1_q16, kd2_q16, kd3_q16, r_max=1.6, n=400):
    """Given the distortion coefficients used to synthesize warped.*,
    numerically fits correction coefficients kc1,kc2,kc3 (same radial
    polynomial form) that approximately invert them -- exactly how a
    real lens-correction coefficient set is derived (fit a polynomial
    inverse to a numerically-inverted forward distortion curve).
    Returns floats (not yet Q16.16-quantized)."""
    kd1, kd2, kd3 = from_q16(kd1_q16), from_q16(kd2_q16), from_q16(kd3_q16)

    def forward(ru):
        return ru * (1 + kd1 * ru**2 + kd2 * ru**4 + kd3 * ru**6)

    ru_samples = np.linspace(0.001, r_max, n)
    rd_samples = np.array([forward(ru) for ru in ru_samples])

    # keep monotonic, physically-sensible region only
    valid = np.gradient(rd_samples, ru_samples) > 0
    ru_samples, rd_samples = ru_samples[valid], rd_samples[valid]

    # solve  (ru/rd - 1) = kc1*rd^2 + kc2*rd^4 + kc3*rd^6   (linear LS)
    target = ru_samples / rd_samples - 1.0
    A = np.stack([rd_samples**2, rd_samples**4, rd_samples**6], axis=1)
    kc, *_ = np.linalg.lstsq(A, target, rcond=None)
    return float(kc[0]), float(kc[1]), float(kc[2])


def load_image(path: str) -> np.ndarray:
    img = Image.open(path).convert("RGB")
    arr = np.array(img, dtype=np.uint8)
    if max(arr.shape[0], arr.shape[1]) > SIM_MAX_DIM:
        scale = SIM_MAX_DIM / max(arr.shape[0], arr.shape[1])
        new_w = max(4, int(arr.shape[1] * scale))
        new_h = max(4, int(arr.shape[0] * scale))
        img = img.resize((new_w, new_h), Image.LANCZOS)
        arr = np.array(img, dtype=np.uint8)
    # even dimensions make life easier and are plenty for a demo/test
    h, w = arr.shape[0] - (arr.shape[0] % 2), arr.shape[1] - (arr.shape[1] % 2)
    return arr[:h, :w, :]


def write_image(path: str, arr: np.ndarray):
    img = Image.fromarray(arr.astype(np.uint8), mode="RGB")
    ext = os.path.splitext(path)[1].lower()
    if ext in (".jpg", ".jpeg"):
        img.save(path, format="JPEG", quality=95)
    else:
        img.save(path, format="PPM")


def sibling_path(original_path: str, stem: str) -> str:
    """warped/corrected filename with the SAME extension family as the
    original test image ('as appropriate', per the spec)."""
    ext = os.path.splitext(original_path)[1].lower()
    if ext not in (".jpg", ".jpeg", ".ppm"):
        ext = ".ppm"
    return os.path.join(os.path.dirname(original_path), stem + ext)


def cubic_weights(t: int):
    """Catmull-Rom (a=-0.5) cubic-convolution weights for the 4 taps at
    relative offsets -1,0,+1,+2 from fractional distance t (Q16.16,
    unsigned, 0<=t<65536). Independent re-derivation of the same
    closed-form polynomial bicubic.sv implements -- written from scratch
    here, not shared code, per this project's verification philosophy.
        w(-1) = -0.5t^3 +    t^2 - 0.5t
        w( 0) =  1.5t^3 - 2.5t^2      + 1
        w(+1) = -1.5t^3 + 2.0t^2 + 0.5t
        w(+2) =  0.5t^3 - 0.5t^2
    """
    NEG_HALF, HALF, ONE = to_q16(-0.5), to_q16(0.5), to_q16(1.0)
    ONE_HALF, NEG_ONE_HALF, TWO, TWO_HALF = to_q16(1.5), to_q16(-1.5), to_q16(2.0), to_q16(2.5)
    t2 = qmul(t, t)
    t3 = qmul(t2, t)
    w0 = qmul(NEG_HALF, t3) + t2 - qmul(HALF, t)
    w1 = qmul(ONE_HALF, t3) - qmul(TWO_HALF, t2) + ONE
    w2 = qmul(NEG_ONE_HALF, t3) + qmul(TWO, t2) + qmul(HALF, t)
    w3 = qmul(HALF, t3) - qmul(HALF, t2)
    return w0, w1, w2, w3


class RemapConfig:
    """Precomputed derived configuration -- mirrors what axi_lite_regs.sv
    computes in hardware from IMG_WIDTH/HEIGHT/CENTER_X/CENTER_Y/SCALE."""

    def __init__(self, w, h, center_x_q16, center_y_q16, scale_q16):
        self.w, self.h = w, h
        imgw_q16 = w << 16
        imgh_q16 = h << 16
        self.cx_pix = qmul(center_x_q16, imgw_q16)
        self.cy_pix = qmul(center_y_q16, imgh_q16)
        self.halfw_scaled = qmul(qmul(imgw_q16, 0x8000), scale_q16)
        self.halfh_scaled = qmul(qmul(imgh_q16, 0x8000), scale_q16)
        self.recip_halfw = fixed_recip(self.halfw_scaled)
        self.recip_halfh = fixed_recip(self.halfh_scaled)


def radial_remap_bicubic_fixed(src: np.ndarray, cfg: RemapConfig, k1_q16, k2_q16, k3_q16) -> np.ndarray:
    """Bicubic counterpart of radial_remap_fixed: same coord_gen math,
    but a 4x4-tap separable Catmull-Rom footprint instead of 2x2
    bilinear -- bit-exact reproduction of the RTL's bicubic gather FSM +
    bicubic.sv. Anchor x0=floor(sx) clamped into [1,w-3] (y0 into
    [1,h-3]) exactly as the RTL does, with t forced to 0 at either clamp
    boundary. Requires w>=4, h>=4 (same minimum the RTL documents)."""
    w, h = cfg.w, cfg.h
    out = np.zeros((h, w, 3), dtype=np.uint8)
    src_i = src.astype(np.int64)

    for y in range(h):
        dy = (y << 16) - cfg.cy_pix
        ny = qmul(dy, cfg.recip_halfh)
        for x in range(w):
            dx = (x << 16) - cfg.cx_pix
            nx = qmul(dx, cfg.recip_halfw)

            r2 = qmul(nx, nx) + qmul(ny, ny)
            r4 = qmul(r2, r2)
            r6 = qmul(r4, r2)
            t1 = qmul(k1_q16, r2)
            t2 = qmul(k2_q16, r4)
            t3 = qmul(k3_q16, r6)
            factor = ONE_Q16 + t1 + t2 + t3

            sxn = qmul(nx, factor)
            syn = qmul(ny, factor)
            sx = cfg.cx_pix + qmul(sxn, cfg.halfw_scaled)
            sy = cfg.cy_pix + qmul(syn, cfg.halfh_scaled)

            if sx < 0:
                x0, tx = 1, 0
            else:
                x0s = sx >> FRAC_BITS
                if x0s < 1:
                    x0, tx = 1, 0
                elif x0s > (w - 3):
                    x0, tx = w - 3, 0
                else:
                    x0, tx = x0s, sx & 0xFFFF
            if sy < 0:
                y0, ty = 1, 0
            else:
                y0s = sy >> FRAC_BITS
                if y0s < 1:
                    y0, ty = 1, 0
                elif y0s > (h - 3):
                    y0, ty = h - 3, 0
                else:
                    y0, ty = y0s, sy & 0xFFFF

            wx = cubic_weights(tx)
            wy = cubic_weights(ty)

            row_vals = []
            for row in range(4):
                yc = y0 - 1 + row
                acc = np.zeros(3, dtype=np.int64)
                for col in range(4):
                    xc = x0 - 1 + col
                    acc = acc + src_i[yc, xc] * wx[col]
                row_vals.append(acc)

            final = np.zeros(3, dtype=np.int64)
            for row in range(4):
                final = final + np.array([qmul(int(v), wy[row]) for v in row_vals[row]])

            acc = final + 32768
            pix = np.clip(acc >> 16, 0, 255)
            out[y, x] = pix

    return out


def radial_remap_fixed(src: np.ndarray, cfg: RemapConfig, k1_q16, k2_q16, k3_q16) -> np.ndarray:
    """Bit-exact reproduction of coord_gen + addr_expand + bilinear.sv,
    applied to `src` (H,W,3 uint8), producing an (H,W,3 uint8) output of
    the same geometry. This single function is used both to synthesize
    warped.* (fed the distortion k's) and as the golden reference for
    corrected.* (fed the correction k's) -- it is literally the same
    hardware primitive in both roles."""
    w, h = cfg.w, cfg.h
    out = np.zeros((h, w, 3), dtype=np.uint8)
    src_i = src.astype(np.int64)

    for y in range(h):
        dy = (y << 16) - cfg.cy_pix
        ny = qmul(dy, cfg.recip_halfh)
        for x in range(w):
            dx = (x << 16) - cfg.cx_pix
            nx = qmul(dx, cfg.recip_halfw)

            r2 = qmul(nx, nx) + qmul(ny, ny)
            r4 = qmul(r2, r2)
            r6 = qmul(r4, r2)
            t1 = qmul(k1_q16, r2)
            t2 = qmul(k2_q16, r4)
            t3 = qmul(k3_q16, r6)
            factor = ONE_Q16 + t1 + t2 + t3

            sxn = qmul(nx, factor)
            syn = qmul(ny, factor)
            sx = cfg.cx_pix + qmul(sxn, cfg.halfw_scaled)
            sy = cfg.cy_pix + qmul(syn, cfg.halfh_scaled)

            if sx < 0:
                x0 = 0
                fx = 0
            else:
                x0s = sx >> FRAC_BITS
                if x0s > (w - 2):
                    x0 = w - 2
                    fx = 255
                else:
                    x0 = x0s
                    fx = bits(sx, 15, 8)
            if sy < 0:
                y0 = 0
                fy = 0
            else:
                y0s = sy >> FRAC_BITS
                if y0s > (h - 2):
                    y0 = h - 2
                    fy = 255
                else:
                    y0 = y0s
                    fy = bits(sy, 15, 8)

            tl = src_i[y0, x0]
            tr = src_i[y0, x0 + 1]
            bl = src_i[y0 + 1, x0]
            br = src_i[y0 + 1, x0 + 1]

            w00 = (256 - fx) * (256 - fy)
            w10 = fx * (256 - fy)
            w01 = (256 - fx) * fy
            w11 = fx * fy

            acc = tl * w00 + tr * w10 + bl * w01 + br * w11
            acc = acc + 32768
            pix = np.clip(acc >> 16, 0, 255)
            out[y, x] = pix

    return out


def radial_remap_generalized_fixed(src: np.ndarray, cfg: RemapConfig, model_sel_is_radial: bool,
                                    k1_q16, k2_q16, k3_q16, p1_q16, p2_q16) -> np.ndarray:
    """Generalized counterpart of radial_remap_fixed above: additionally
    supports tangential distortion (p1,p2) and the model_sel hook gate
    (model_sel_is_radial=False -> exact identity round trip, k1/k2/k3/
    p1/p2 ignored -- matches coord_gen.sv's ARCHITECTURE HOOK behavior).
    Used by the fisheye/panoramic/perspective image-level hook tests to
    confirm the whole streaming pipeline reproduces its input when one of
    those reserved model IDs is selected, even with nonzero distortion
    coefficients configured (proving the hook genuinely ignores them).
    Bilinear sampling only -- see golden_model_pkg.sv's SystemVerilog
    counterpart for why bicubic is out of scope for this particular
    check."""
    w, h = cfg.w, cfg.h
    out = np.zeros((h, w, 3), dtype=np.uint8)
    src_i = src.astype(np.int64)

    for y in range(h):
        dy = (y << 16) - cfg.cy_pix
        ny = qmul(dy, cfg.recip_halfh)
        for x in range(w):
            dx = (x << 16) - cfg.cx_pix
            nx = qmul(dx, cfg.recip_halfw)

            r2 = qmul(nx, nx) + qmul(ny, ny)
            if model_sel_is_radial:
                r4 = qmul(r2, r2)
                r6 = qmul(r4, r2)
                t1 = qmul(k1_q16, r2)
                t2 = qmul(k2_q16, r4)
                t3 = qmul(k3_q16, r6)
                factor = ONE_Q16 + t1 + t2 + t3
                tangx = (qmul(p1_q16, qmul(nx, ny)) << 1) + qmul(p2_q16, r2 + (qmul(nx, nx) << 1))
                tangy = qmul(p1_q16, r2 + (qmul(ny, ny) << 1)) + (qmul(p2_q16, qmul(nx, ny)) << 1)
            else:
                factor = ONE_Q16
                tangx = 0
                tangy = 0

            sxn = qmul(nx, factor) + tangx
            syn = qmul(ny, factor) + tangy
            sx = cfg.cx_pix + qmul(sxn, cfg.halfw_scaled)
            sy = cfg.cy_pix + qmul(syn, cfg.halfh_scaled)

            if sx < 0:
                x0 = 0
                fx = 0
            else:
                x0s = sx >> FRAC_BITS
                if x0s > (w - 2):
                    x0 = w - 2
                    fx = 255
                else:
                    x0 = x0s
                    fx = bits(sx, 15, 8)
            if sy < 0:
                y0 = 0
                fy = 0
            else:
                y0s = sy >> FRAC_BITS
                if y0s > (h - 2):
                    y0 = h - 2
                    fy = 255
                else:
                    y0 = y0s
                    fy = bits(sy, 15, 8)

            tl = src_i[y0, x0]
            tr = src_i[y0, x0 + 1]
            bl = src_i[y0 + 1, x0]
            br = src_i[y0 + 1, x0 + 1]

            w00 = (256 - fx) * (256 - fy)
            w10 = fx * (256 - fy)
            w01 = (256 - fx) * fy
            w11 = fx * fy

            acc = tl * w00 + tr * w10 + bl * w01 + br * w11
            acc = acc + 32768
            pix = np.clip(acc >> 16, 0, 255)
            out[y, x] = pix

    return out
