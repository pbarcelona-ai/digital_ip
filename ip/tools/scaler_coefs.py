#!/usr/bin/env python3
"""
scaler_coefs.py - register and coefficient derivation for the scaler IP family.

Implements the method documented in docs/coefficient_derivation.md. The
polyphase table generator is a line-by-line mirror of
scalers/scaler_tb_lib/src/scaler_coef_gen.svh, so software and testbenches program the
hardware identically.

Examples
  # Catmull-Rom bicubic, 1920x1080 -> 1280x720, register writes
  scaler_coefs.py polyphase --kernel cubic --B 0 --C 0.5 --taps 4 \
      --in 1920 1080 --out 1280 720

  # Lanczos-3 as a C header
  scaler_coefs.py polyphase --kernel lanczos --a 3 --taps 6 \
      --in 1280 720 --out 1920 1080 --format c > lanczos3_720p_1080p.h

  # 8-tap anti-aliased downscale on scaler_polyphase, with quality report
  scaler_coefs.py polyphase --kernel lanczos --a 2 --taps 8 \
      --in 3840 2160 --out 1920 1080 --report

  # Trilinear / anisotropic register values
  scaler_coefs.py trilinear   --in 1920 1080 --out 480 270 --levels 4
  scaler_coefs.py anisotropic --in 1920 1080 --out 1920 135 --levels 5 --aniso-max 4

  # Nearest / bilinear / edge-directed only need the common registers
  scaler_coefs.py common --in 640 480 --out 1920 1080

  # Contrast-adaptive sharpening (same size) and the FSR 1-style upscaler
  scaler_coefs.py sharpen  --in 1920 1080 --sharpness 96
  scaler_coefs.py upscaler --in 1280 720 --out 1920 1080 --sharpness 128
"""
import argparse
import math
import sys

# ----------------------------------------------------------------------------
# Register map constants (see scaler_ctrl, scaler_polyphase, scaler_mip)
# ----------------------------------------------------------------------------
REG_CTRL, REG_STATUS, REG_IN_SIZE, REG_OUT_SIZE = 0x000, 0x004, 0x008, 0x00C
REG_STEP_X, REG_STEP_Y, REG_OFFS_X, REG_OFFS_Y = 0x010, 0x014, 0x018, 0x01C
COEF_H_BASE, COEF_V_BASE, COEF_STRIDE = 0x1000, 0x2000, 16
REG_LOD, REG_ANISO, REG_PSTEP_X, REG_PSTEP_Y = 0x040, 0x044, 0x048, 0x04C
REG_PSTART_X, REG_PSTART_Y = 0x050, 0x054
REG_THRESH, REG_EDGE_CTRL = 0x040, 0x044


def u32(v):
    return v & 0xFFFFFFFF


# ----------------------------------------------------------------------------
# 1. Coordinate mapping (all IPs)
# ----------------------------------------------------------------------------
def calc_step(in_sz, out_sz):
    """STEP = round(in/out * 2^16), unsigned 16.16."""
    return ((in_sz << 16) + out_sz // 2) // out_sz


def calc_offs(step):
    """OFFS = STEP/2 - 0.5 (pixel-centre alignment), signed 16.16."""
    return (step >> 1) - 0x8000


def common_regs(in_w, in_h, out_w, out_h):
    sx, sy = calc_step(in_w, out_w), calc_step(in_h, out_h)
    return [
        (REG_IN_SIZE, (in_h << 16) | in_w, "IN_SIZE"),
        (REG_OUT_SIZE, (out_h << 16) | out_w, "OUT_SIZE"),
        (REG_STEP_X, sx, "STEP_X  = %.6f" % (sx / 65536)),
        (REG_STEP_Y, sy, "STEP_Y  = %.6f" % (sy / 65536)),
        (REG_OFFS_X, u32(calc_offs(sx)), "OFFS_X  = %.6f" % (calc_offs(sx) / 65536)),
        (REG_OFFS_Y, u32(calc_offs(sy)), "OFFS_Y  = %.6f" % (calc_offs(sy) / 65536)),
    ]


# ----------------------------------------------------------------------------
# 2. Kernels
# ----------------------------------------------------------------------------
def kernel_cubic(x, B, C):
    """Mitchell-Netravali (B, C) cubic family."""
    ax = abs(x)
    if ax < 1.0:
        return ((12 - 9 * B - 6 * C) * ax ** 3 + (-18 + 12 * B + 6 * C) * ax ** 2
                + (6 - 2 * B)) / 6.0
    if ax < 2.0:
        return ((-B - 6 * C) * ax ** 3 + (6 * B + 30 * C) * ax ** 2
                + (-12 * B - 48 * C) * ax + (8 * B + 24 * C)) / 6.0
    return 0.0


def kernel_lanczos(x, a):
    """Lanczos-a windowed sinc."""
    ax = abs(x)
    if ax < 1e-9:
        return 1.0
    if ax >= a:
        return 0.0
    return a * math.sin(math.pi * ax) * math.sin(math.pi * ax / a) / (math.pi ** 2 * ax * ax)


# ----------------------------------------------------------------------------
# 3. Polyphase tables
# ----------------------------------------------------------------------------
def gen_coefs(kernel, taps, phase_bits, frac, coef_w, scale):
    """
    Returns table[phase][tap] of signed integers.

    tap t of phase p sits at distance  d = (t - ctr) - p/P  from the sample
    point (ctr = (taps-1)//2). Weights are K(d/s) with s = max(1, scale),
    normalised to sum 1, quantised with round-half-up, and the rounding
    residue is added to the largest coefficient so every phase sums to
    exactly 2^frac (unity DC gain, no flat-field drift).
    """
    phases = 1 << phase_bits
    ctr = (taps - 1) // 2
    s = max(1.0, scale)
    one = 1 << frac
    cmax, cmin = (1 << (coef_w - 1)) - 1, -(1 << (coef_w - 1))
    table = []
    for p in range(phases):
        f = p / phases
        w = [kernel(((t - ctr) - f) / s) for t in range(taps)]
        total = sum(w)
        q = [int(math.floor(v / total * one + 0.5)) for v in w]
        big = 0
        for t in range(taps):
            if q[t] > q[big]:
                big = t
        q[big] += one - sum(q)
        table.append([min(cmax, max(cmin, v)) for v in q])
    return table


def table_report(name, table, frac, taps, scale, kernel_support):
    one = 1 << frac
    phases = len(table)
    dc_ok = all(sum(row) == one for row in table)
    peak = max(max(abs(c) for c in row) for row in table) / one
    # Response at output Nyquist (worst over phases): sum c_t * cos(pi * d / s)
    s = max(1.0, scale)
    ctr = (taps - 1) // 2
    nyq = 0.0
    for p, row in enumerate(table):
        d = [(t - ctr) - p / phases for t in range(taps)]
        re = sum(c / one * math.cos(math.pi * dd / s) for c, dd in zip(row, d))
        im = sum(c / one * math.sin(math.pi * dd / s) for c, dd in zip(row, d))
        nyq = max(nyq, math.hypot(re, im))
    need = int(math.ceil(2 * kernel_support * s))
    msg = [f"{name}: phases={phases} taps={taps} scale={scale:.4f}",
           f"  DC gain exact on all phases : {'yes' if dc_ok else 'NO'}",
           f"  largest |coefficient|       : {peak:.4f}",
           f"  worst |H| at output Nyquist : {nyq:.4f}  (aliasing indicator, lower is better)",
           f"  taps needed for full kernel : {need}" + ("" if need <= taps else
               f"  -> kernel TRUNCATED to {taps} taps; consider more taps or trilinear")]
    return "\n".join(msg)


def coef_regs(base, table):
    out = []
    for p, row in enumerate(table):
        for t, c in enumerate(row):
            out.append((base + 4 * (COEF_STRIDE * p + t), u32(c), f"p{p:02d} t{t}"))
    return out


# ----------------------------------------------------------------------------
# 4. Mip-map (trilinear / anisotropic)
# ----------------------------------------------------------------------------
def mip_regs(step_x, step_y, levels, aniso_max):
    """
    Footprint of one output pixel in level-0 pixels: sx = STEP_X/2^16,
    sy = STEP_Y/2^16 (clamped to >= 1: magnification needs no pre-filter).
      N    = 2^clamp(round(log2(major/minor)), 0, aniso_max)   probes
      LOD  = max(0, log2(major / N))                           8.8 fixed point
      probe spacing d = major / N along the major axis,
      PROBE_START = -(N-1)/2 * PROBE_STEP  (probes centred on the pixel)
    """
    sx, sy = step_x / 65536.0, step_y / 65536.0
    fmaj, fmin = (sx, sy) if sx > sy else (sy, sx)
    fmaj, fmin = max(fmaj, 1.0), max(fmin, 1.0)
    alog2 = 0
    if aniso_max > 0:
        alog2 = int(math.floor(math.log2(fmaj / fmin) + 0.5))
        alog2 = max(0, min(aniso_max, alog2))
    n = 1 << alog2
    lod = max(0.0, math.log2(fmaj / n))
    lod_reg = int(math.floor(lod * 256 + 0.5))
    d = fmaj / n
    psx = psy = 0
    if alog2 > 0:
        if sx >= sy:
            psx = int(math.floor(d * 65536 + 0.5))
        else:
            psy = int(math.floor(d * 65536 + 0.5))
    pstart_x = -((psx * (n - 1)) >> 1)
    pstart_y = -((psy * (n - 1)) >> 1)
    if (lod_reg >> 8) >= levels - 1 and lod > levels - 1:
        print(f"# note: LOD {lod:.2f} exceeds top level {levels-1}; output will alias "
              f"(instantiate more LEVELS)", file=sys.stderr)
    return [
        (REG_LOD, lod_reg, "LOD = %.4f" % (lod_reg / 256)),
        (REG_ANISO, alog2, f"ANISO_LOG2 ({n} probes)"),
        (REG_PSTEP_X, u32(psx), "PROBE_STEP_X = %.6f" % (psx / 65536)),
        (REG_PSTEP_Y, u32(psy), "PROBE_STEP_Y = %.6f" % (psy / 65536)),
        (REG_PSTART_X, u32(pstart_x), "PROBE_START_X = %.6f" % (pstart_x / 65536)),
        (REG_PSTART_Y, u32(pstart_y), "PROBE_START_Y = %.6f" % (pstart_y / 65536)),
    ]


# ----------------------------------------------------------------------------
# 5. Contrast-adaptive sharpening (sharpen_cas, spatial_upscaler at 0x4000)
# ----------------------------------------------------------------------------
def cas_gain(sharpness):
    """G = round(65536 / (1024 - 3*S)): Q8 peak unsharp gain 0.25 .. 1.0."""
    d = 1024 - 3 * sharpness
    return (65536 + d // 2) // d


def sharpen_regs(w, h, sharpness, base, bypass):
    if not 0 <= sharpness <= 256:
        raise SystemExit("sharpness must be 0..256")
    return [
        (base + 0x008, (h << 16) | w, "CAS SIZE"),
        (base + 0x040, sharpness, "CAS SHARPNESS (gain %.3f)" % (cas_gain(sharpness) / 256)),
        (base + 0x004, 0xE, "CAS clear sticky status"),
        (base + 0x000, 3 if bypass else 1, "CAS ENABLE" + (" + BYPASS" if bypass else "")),
    ]


# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
def emit(regs, fmt, name):
    if fmt == "regs":
        for a, v, c in regs:
            print(f"0x{a:04X} 0x{v:08X}  # {c}")
    elif fmt == "c":
        guard = name.upper()
        print(f"/* generated by scaler_coefs.py */\n#ifndef {guard}_H\n#define {guard}_H")
        print("#include <stdint.h>")
        print(f"static const uint32_t {name}[][2] = {{  /* {{offset, value}} */")
        for a, v, c in regs:
            print(f"  {{0x{a:04X}u, 0x{v:08X}u}},  /* {c} */")
        print(f"}};\n#define {guard}_COUNT {len(regs)}u\n#endif")
    elif fmt == "sv":
        for a, v, c in regs:
            print(f"axil_write(16'h{a:04X}, 32'h{v:08X});  // {c}")
    else:
        raise SystemExit("unknown format")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("method", choices=["common", "polyphase", "trilinear", "anisotropic",
                                       "sharpen", "upscaler"])
    ap.add_argument("--in", dest="inp", nargs=2, type=int, required=True, metavar=("W", "H"))
    ap.add_argument("--out", nargs=2, type=int, metavar=("W", "H"),
                    help="output size (not used by 'sharpen')")
    ap.add_argument("--sharpness", type=int, default=128,
                    help="sharpen / upscaler: SHARPNESS 0..256")
    ap.add_argument("--bypass", action="store_true", help="sharpen: set CTRL.BYPASS")
    ap.add_argument("--kernel", choices=["cubic", "lanczos"], default="cubic")
    ap.add_argument("--B", type=float, default=0.0, help="cubic B (0 = Catmull-Rom family)")
    ap.add_argument("--C", type=float, default=0.5, help="cubic C (0.5 = Catmull-Rom)")
    ap.add_argument("--a", type=float, default=3.0, help="Lanczos lobes")
    ap.add_argument("--taps", type=int, default=4)
    ap.add_argument("--phase-bits", type=int, default=6)
    ap.add_argument("--coef-w", type=int, default=16)
    ap.add_argument("--frac", type=int, default=14)
    ap.add_argument("--no-aa", action="store_true", help="do not stretch kernel on downscale")
    ap.add_argument("--levels", type=int, default=4)
    ap.add_argument("--aniso-max", type=int, default=0)
    ap.add_argument("--format", choices=["regs", "c", "sv"], default="regs")
    ap.add_argument("--name", default="scaler_cfg")
    ap.add_argument("--report", action="store_true", help="print filter quality report to stderr")
    args = ap.parse_args()

    (iw, ih) = args.inp
    if args.method == "sharpen":
        emit(sharpen_regs(iw, ih, args.sharpness, 0, args.bypass), args.format, args.name)
        return
    if args.out is None:
        raise SystemExit("--out W H is required for method " + args.method)
    (ow, oh) = args.out
    regs = common_regs(iw, ih, ow, oh)

    if args.method == "upscaler":
        # Lanczos-3, 6 taps, anti-aliased, then the sharpener at 0x4000
        for base, i, o in ((COEF_H_BASE, iw, ow), (COEF_V_BASE, ih, oh)):
            tab = gen_coefs(lambda x: kernel_lanczos(x, 3.0), 6, args.phase_bits,
                            args.frac, args.coef_w, i / o)
            regs += coef_regs(base, tab)
        regs += sharpen_regs(ow, oh, args.sharpness, 0x4000, False)
    elif args.method == "polyphase":
        if args.taps % 2 or not 2 <= args.taps <= 16:
            raise SystemExit("taps must be even, 2..16")
        if args.kernel == "cubic":
            kern = lambda x: kernel_cubic(x, args.B, args.C)
            support = 2.0
        else:
            kern = lambda x: kernel_lanczos(x, args.a)
            support = args.a
        for base, name, i, o in ((COEF_H_BASE, "H", iw, ow), (COEF_V_BASE, "V", ih, oh)):
            scale = 1.0 if args.no_aa else i / o
            tab = gen_coefs(kern, args.taps, args.phase_bits, args.frac, args.coef_w, scale)
            regs += coef_regs(base, tab)
            if args.report:
                print(table_report(name, tab, args.frac, args.taps, scale, support), file=sys.stderr)
    elif args.method in ("trilinear", "anisotropic"):
        am = 0 if args.method == "trilinear" else (args.aniso_max or 4)
        regs += mip_regs(calc_step(iw, ow), calc_step(ih, oh), args.levels, am)

    regs.append((REG_STATUS, 0xE, "clear sticky status"))
    regs.append((REG_CTRL, 1, "ENABLE"))
    emit(regs, args.format, args.name)


if __name__ == "__main__":
    main()
