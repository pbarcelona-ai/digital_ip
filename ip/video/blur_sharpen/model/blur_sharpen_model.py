"""blur_sharpen model (Python model of ip/video/blur_sharpen/src/blur_sharpen_top.sv), frame exact: its register
block (blur_sharpen_regs.json; the reset kernels the binomial blur and the sharpen of AMOUNT, both shifts
2 (N - 1)) and two conv2d_core passes (conv2d_core_model.conv2d, BORDER rule, CW-bit components):
  MODE 0 blur, 1 sharpen, 2 sharpen then blur, 3 blur then sharpen, 4-7 pass-through (identity kernels).
Kernel coefficients are signed COEF_W-bit (a register reads back the low COEF_W bits). MODE, FRAME_SIZE, the
kernels and the shifts are taken when the frame's start-of-frame pixel enters, so registers written between
frames apply from the next frame. STATUS: [2:0] the mode of the last frame that entered, [31:16] the frames
out; INFO: N, COEF_W, C, CW. Frames match FRAME_SIZE and have at least 14 pixels (the RTL's per-frame copy for
stage 2 is replaced at the next start of frame; see blur_sharpen.sv)."""
from conv2d_core_model import conv2d
from pixel import signed
from regs import RegMap, ip_regs

N = 5                          # kernel size of the design (video_processor FILT_N)


def _binom(n, i):
    if n == 3:
        return 2 if i == 1 else 1
    return {0: 1, 4: 1, 1: 4, 3: 4}.get(i, 6)


def blur_kernel(n):
    """Binomial blur, sum 2**(2 (n - 1))."""
    return [_binom(n, r) * _binom(n, c) for r in range(n) for c in range(n)]


def sharpen_kernel(n, amount):
    """Unsharp mask: (1 + amount) x identity - amount x blur, the blur's scale."""
    one = 1 << (2 * (n - 1))
    return [((1 + amount) * one if (r == n // 2 and c == n // 2) else 0) - amount * _binom(n, r) * _binom(n, c)
            for r in range(n) for c in range(n)]


def _pack(k):
    """A kernel as the JSON reset value of the coefficient array (32 bits per coefficient)."""
    v = 0
    for i, c in enumerate(k):
        v |= (c & 0xFFFFFFFF) << (32 * i)
    return v


def blur_sharpen(r, img, n=N, coef_w=12, border=0, cw=8):
    """blur_sharpen (register map r): MODE 0 blur, 1 sharpen, 2 sharpen then blur, 3 blur then sharpen,
    other modes pass the frame through."""
    mode = r.get("MODE") & 7
    kb = [signed(r.get("BLUR_K", i), coef_w) for i in range(n * n)]
    ks = [signed(r.get("SHARP_K", i), coef_w) for i in range(n * n)]
    sb, ss = r.get("BLUR_SHIFT"), r.get("SHARP_SHIFT")

    def blur(x):
        return conv2d(x, kb, sb, n, border, cw)

    def sharp(x):
        return conv2d(x, ks, ss, n, border, cw)
    if mode == 0:
        return blur(img)
    if mode == 1:
        return sharp(img)
    if mode == 2:
        return blur(sharp(img))
    if mode == 3:
        return sharp(blur(img))
    return img


class BlurSharpen:
    """One blur_sharpen instance (the RTL parameters): registers, frame count, run(frame)."""

    def __init__(self, n=N, c=3, cw=8, coef_w=12, border=0, amount=1, reset_w=1920, reset_h=1080):
        self.n, self.c, self.cw, self.coef_w, self.border = n, c, cw, coef_w, border
        self.r = RegMap(ip_regs(__file__, "blur_sharpen"),
                        {"N": n, "COEF_W": coef_w, "RESET_W": reset_w, "RESET_H": reset_h,
                         "K_BLUR": _pack(blur_kernel(n)), "K_SHARP": _pack(sharpen_kernel(n, amount))})
        self.frames = 0
        self.mode = 0                                    # the mode of the last frame that entered
        self.r.sts = lambda name, i: ({"STATUS": self.mode | ((self.frames & 0xFFFF) << 16),
                                       "INFO": n | (coef_w << 8) | (c << 16) | (cw << 24)}.get(name, 0))

    def run(self, img):
        """One frame (H x W x C, the size in FRAME_SIZE): the filtered frame."""
        self.mode = self.r.get("MODE") & 7
        out = blur_sharpen(self.r, img, self.n, self.coef_w, self.border, self.cw)
        self.frames += 1
        return out
