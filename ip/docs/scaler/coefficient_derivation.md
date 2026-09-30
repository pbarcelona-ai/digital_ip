# Deriving Scaler Coefficients and Registers for Any Scaling Factor

This document defines how every programmable value of the scaler IP family is derived from the input size, the output size and the chosen kernel. The reference implementation is `tools/scaler_coefs.py`. `scalers/scaler_tb_lib/src/scaler_coef_gen.svh` mirrors it line for line; both were checked to produce bit-identical tables across seven kernel, tap-count and scale combinations.

The derivation has four layers, and each IP uses the layers it needs:

| IP | Coordinate map (§1) | Phase quantisation (§2) | Weights |
|---|---|---|---|
| scaler_nearest | yes | 0 bits (round) | none |
| scaler_bilinear | yes | 8 bits | computed in hardware (§3) |
| scaler_edge_directed | yes | 8 bits | computed in hardware (§4) |
| scaler_bicubic / scaler_lanczos / scaler_polyphase | yes | 6 bits | programmed tables (§5) |
| scaler_trilinear / scaler_anisotropic | yes | 8 bits | hardware bilinear + LOD / probe registers (§6) |

## 1. Coordinate mapping (all IPs)

Output pixel `(ox, oy)` is mapped to a continuous source position with pixel-centre alignment. The centre of output pixel `o` lands on the corresponding point of the input:

```
src(o) = (o + 0.5) * (in / out) - 0.5
       = OFFS + o * STEP
STEP   = in / out                 (source pixels per output pixel)
OFFS   = STEP / 2 - 0.5
```

The hardware (`scaler_dda`) holds both values in 16.16 fixed point and replaces the multiplication with an exact accumulation:

```
STEP_X = round(in_w * 2^16 / out_w)          = ((in_w << 16) + out_w/2) // out_w
OFFS_X = (STEP_X >> 1) - 0x8000              (signed)
```

The same formulas apply for Y.

**Error bound.** Quantising STEP introduces at most 2^-17 source pixels of error per output pixel. The error accumulates linearly, so after `out` pixels the drift is at most `out / 2^17`. That is 0.015 px at 1920 wide and 0.06 px at 7680 wide, well inside one phase step (1/64 px) at typical widths. Applications that need exact end-point alignment can nudge `OFFS` by half the accumulated error.

**Line-buffer builds.** IPs built with `LINE_BUF=1` read source rows in increasing order, so they require `STEP_Y ≥ 0`. `OFFS_Y` may be negative; rows above the image clamp to row 0, as in the other modes.

**Other alignments.** The registers are free-form, so other conventions are just different values. Corner alignment (`src = o * (in-1)/(out-1)`) uses `STEP = (in-1)/(out-1)` and `OFFS = 0`. Crop and pan use `OFFS += crop_origin`. Mirroring uses a negative step, written as a two's-complement value.

**Example (1280 → 1920).** `STEP = 43691` (0.666672) and `OFFS = −10923` (−0.166672).

## 2. Phase quantisation

The data path needs an integer tap position `i` and a sub-pixel phase `p` with `PB` bits. The source coordinate is rounded, not truncated, to the phase grid:

```
s_r = s + 2^(16 - PB - 1)
i   = s_r >>> 16                      (floor)
p   = s_r[15 : 16-PB]                 fractional phase, 0 .. 2^PB - 1
f   = p / 2^PB                        the phase actually filtered
```

Nearest neighbour is the special case `PB = 0`, which gives `i = floor(s + 0.5)`.

Rounding to the grid adds at most ½·2^-PB px of position error. That is 1/128 px for polyphase (PB = 6) and 1/512 px for the bilinear family (PB = 8). Both are below the visibility threshold for 8-bit video.

## 3. Bilinear weights (hardware)

With `ONE = 2^PB`, `fx = p_x` and `fy = p_y`:

```
top = p00 (ONE - fx) + p01 fx
bot = p10 (ONE - fx) + p11 fx
out = (top (ONE - fy) + bot fy + ONE^2/2) >> 2 PB
```

The weights are exact integers that always sum to `ONE²`. The result is a convex combination, so it can never overflow or need clamping. Software only programs the §1 registers.

## 4. Edge-directed weights (hardware)

For the 2×2 cell, the IP computes two diagonal activity measures:

```
d1 = Σc |p00 − p11|
d2 = Σc |p01 − p10|
```

If `d1 + THRESH < d2`, an edge runs along the p00–p11 diagonal. The cell is then split along that diagonal and the output is the linear (barycentric) interpolation inside the triangle that contains the sample point. The opposite condition splits along p01–p10. Otherwise the IP uses plain bilinear. All weights are integers in units of `ONE²`:

| Case | Condition | w00 | w01 | w10 | w11 |
|---|---|---|---|---|---|
| `\` split | fx ≥ fy | (ONE−fx)·ONE | (fx−fy)·ONE | 0 | fy·ONE |
| `\` split | fx < fy | (ONE−fy)·ONE | 0 | (fy−fx)·ONE | fx·ONE |
| `/` split | fx+fy ≤ ONE | (ONE−fx−fy)·ONE | fx·ONE | fy·ONE | 0 |
| `/` split | fx+fy > ONE | 0 | (ONE−fy)·ONE | (ONE−fx)·ONE | (fx+fy−ONE)·ONE |
| flat | otherwise | (ONE−fx)(ONE−fy) | fx(ONE−fy) | (ONE−fx)fy | fx·fy |

**Choosing THRESH.** THRESH is compared against a sum over `CHANNELS` components, so scale it with the channel count. A good starting point is `THRESH ≈ 4 × σ_noise × CHANNELS`, where σ_noise is the per-component noise level. The reset value of 16 suits clean 8-bit RGB. Set `THRESH = 0` for maximum edge adaptivity. Setting `EDGE_EN = 0` makes the IP bit-identical to `scaler_bilinear`, which the testbench verifies.

## 5. Polyphase FIR coefficients (bicubic, Lanczos, generic)

### 5.1 Tap geometry

`TAPS` is even. For phase `p` (fraction `f = p / 2^PB`), tap `t` sits at a signed distance from the sample point:

```
ctr  = TAPS/2 − 1                     (tap at the integer position i)
d_t  = (t − ctr) − f                  t = 0 .. TAPS−1
```

For example, TAPS = 4 gives distances `−1−f, −f, 1−f, 2−f`, and the window starts at `i − ctr`.

### 5.2 Kernels

The **Mitchell–Netravali cubic family** has two parameters `(B, C)`:

```
|x| < 1 : ((12−9B−6C)|x|³ + (−18+12B+6C)|x|² + (6−2B)) / 6
|x| < 2 : ((−B−6C)|x|³ + (6B+30C)|x|² + (−12B−48C)|x| + (8B+24C)) / 6
else    : 0
```

| Name | B | C | Character |
|---|---|---|---|
| Catmull-Rom (Keys a = −0.5) | 0 | 0.5 | sharp, interpolating |
| Keys a = −0.75 | 0 | 0.75 | sharper, more ringing |
| Mitchell | 1/3 | 1/3 | balanced (recommended for photos) |
| Cubic B-spline | 1 | 0 | smooth, no ringing, blurs |

The **Lanczos-a** kernel is `L(x) = sinc(x) · sinc(x/a)` for `|x| < a` and 0 elsewhere, with `sinc(x) = sin(πx)/(πx)`. It needs `2a` taps: Lanczos-2 uses 4, Lanczos-3 uses 6 and Lanczos-4 uses 8.

### 5.3 Anti-aliasing stretch for downscaling

When `scale = in/out > 1`, the kernel must be widened by `s = max(1, scale)`. This lowers its cut-off to the output Nyquist frequency:

```
w_t = K(d_t / s)
```

The widened kernel covers `2 · support · s` input pixels, where support is 2 for cubic and `a` for Lanczos. If this exceeds `TAPS`, the kernel is truncated. It is still correctly normalised, but aliasing rises. `scaler_coefs.py --report` prints both the tap requirement and an aliasing indicator (the worst-case response at the output Nyquist frequency).

Practical guidance:

| scale | recommendation |
|---|---|
| ≤ 1 (upscale) | no stretch; 4 taps for cubic, 6 for Lanczos-3 |
| 1 … 2 | stretch; 4–6 taps acceptable, 8 ideal (`scaler_polyphase` TAPS = 8) |
| 2 … 4 | `scaler_polyphase` with 8–16 taps, or trilinear followed by polyphase |
| > 4 | `scaler_trilinear` / `scaler_anisotropic` (mip pre-filtering) |

`--no-aa` disables the stretch. Use it when a sharp but aliased downscale is intended, such as pixel art.

### 5.4 Normalisation and quantisation

Each phase is processed independently:

1. **Normalise.** Compute `n_t = w_t / Σ w`, so that the DC gain is exactly 1.
2. **Quantise.** Round half up: `q_t = floor(n_t · 2^F + 0.5)`. The default is `F = COEF_FRAC = 14` with `COEF_W = 16`, giving a range of ±2.
3. **Remove the residue.** Add `2^F − Σ q` to the largest coefficient. The first one wins on ties, so the choice is deterministic. Every phase then sums to exactly `2^F`. This matters because otherwise flat areas would pulse with the phase pattern (e.g. a grey level alternating 127/128 in a fixed spatial rhythm).
4. **Saturate.** Clamp to the signed `COEF_W` range. This is never reached for the kernels above.

### 5.5 Data-path arithmetic (for reference models)

```
v_k  = (Σ_j CV[p_y][j] · in[y0+j][x0+k] + 2^(F−1)) >>> F        vertical, per column
out  = clamp((Σ_k CH[p_x][k] · v_k + 2^(F−1)) >>> F, 0, 2^COMP_W − 1)
```

The intermediate `v_k` keeps its sign and headroom, and only the final result is clamped. That clamp absorbs Lanczos and Catmull-Rom overshoot.

### 5.6 Programming

The horizontal table lives at `0x1000 + 4·(16·p + t)` and the vertical table at `0x2000 + 4·(16·p + t)`. Write `TAPS × 2^PB` words per table. Separate H and V tables allow different X and Y scale factors (and even different kernels). Update the tables only while `STATUS.BUSY = 0`. Out of reset the tables contain bilinear weights.

### 5.7 Worked examples (PB = 6, F = 14)

| Kernel, scale | Phase | Coefficients (t = 0 …) | Σ |
|---|---|---|---|
| Catmull-Rom, 1.0 | 0 | 0, 16384, 0, 0 | 16384 |
| Catmull-Rom, 1.0 | 16 (f = ¼) | −1152, 14208, 3712, −384 | 16384 |
| Catmull-Rom, 1.0 | 32 (f = ½) | −1024, 9216, 9216, −1024 | 16384 |
| Lanczos-3, 1.0 | 32 | 401, −2226, 10017, 10017, −2226, 401 | 16384 |
| Catmull-Rom, 2.0, 8 taps | 0 | −512, 0, 4608, 8192, 4608, 0, −512, 0 | 16384 |
| Catmull-Rom, 1.5 (1080p→720p), 4 taps | 0 | 3429, 10288, … | 16384 |

As a sanity check, the unquantised Catmull-Rom weights at f = ¼ are −0.0703, 0.8672, 0.2266 and −0.0234. Multiplied by 16384 and rounded, they give the phase-16 row above.

## 6. Mip-map scalers: LOD and anisotropic probes

### 6.1 Pyramid

The hardware builds level `k+1` from level `k` with a 2×2 box filter, `(a+b+c+d+2) >> 2`. Sizes follow `W[k+1] = max(1, W[k] >> 1)`, and odd sizes use clamp-to-edge. Level `k` pixel `u_k` corresponds to level-0 coordinate `(u_k + 0.5)·2^k − 0.5`, which inverts to:

```
u_k = ((u + 0.5) >> k) − 0.5
```

The hardware evaluates this in 16.16 fixed point for every probe.

### 6.2 Footprint

The footprint of one output pixel, in level-0 pixels, is `Fx = STEP_X / 2^16` and `Fy = STEP_Y / 2^16`. Values below 1 (magnification) are clamped to 1 because no pre-filtering is needed. Let `major = max(Fx, Fy)` and `minor = min(Fx, Fy)`.

### 6.3 Trilinear

```
LOD     = max(0, log2(major))
LOD_REG = round(256 · LOD)            8.8 fixed point → level L = LOD_REG[15:8], blend f = LOD_REG[7:0]
out     = (bil(L) · (256 − f) + bil(L+1) · f + 128) >> 8
```

Using `major` is conservative: it never aliases, but it blurs the less-reduced axis. That blur is exactly what the anisotropic IP removes. At or above the top level, the hardware clamps to `L = LEVELS−1, f = 0`. The number of levels needed is `LEVELS ≥ ceil(log2(max scale)) + 1`.

### 6.4 Anisotropic

The IP takes several probes spread along the major axis, so the LOD can follow the minor axis:

```
N          = 2^clamp(round(log2(major / minor)), 0, ANISO_MAX_LOG2)
LOD        = max(0, log2(major / N))
d          = major / N                           probe spacing, level-0 px
PROBE_STEP = (d, 0) if Fx ≥ Fy else (0, d)       16.16
PROBE_START= −(N − 1)/2 · PROBE_STEP             probes centred on the pixel
out        = (Σ_n trilinear(src + PROBE_START + n·PROBE_STEP) + N/2) >> log2 N
```

The probes jointly cover the `major` extent, and each one filters an approximately square `d × d` area. Throughput is 1/N output pixels per clock, so choose `ANISO_MAX_LOG2` to match the pixel-rate budget. The probe registers accept any vector, so rotated or sheared footprints (warping) are also possible.

**Example (1920×1080 → 1920×135, a 1 : 8 vertical squeeze).** Fx = 1 and Fy = 8, so N = 8, LOD = 0, `PROBE_STEP_Y = 1.0` and `PROBE_START_Y = −3.5`. Each output pixel therefore averages 8 bilinear samples of level 0, one per input row, with no horizontal blur. Plain trilinear would instead pick LOD 3 and blur X by 8×.

## 7. Programming sequence (all IPs)

1. Wait for `STATUS.BUSY = 0`, or write `CTRL = 0` and poll.
2. Write `IN_SIZE`, `OUT_SIZE`, `STEP_X/Y` and `OFFS_X/Y` (§1).
3. Write the IP-specific values: coefficient tables (§5), `THRESH` (§4) or LOD/probe registers (§6).
4. Write `STATUS = 0xE` to clear the sticky flags, then `CTRL = 1`.
5. Stream frames. `FRAME_CNT` increments and `STATUS.FRAME_DONE` is set after each output frame.

`scaler_coefs.py` emits exactly this sequence as `addr value` pairs, a C header (`--format c`), or SystemVerilog `axil_write` calls (`--format sv`).

## 8. Contrast-adaptive sharpening (sharpen_cas)

The sharpener has no coefficient tables. Its only programmable value is `SHARPNESS` (0–256), and everything else is derived per pixel in hardware from the 3×3 neighbourhood. The formulation follows AMD FidelityFX CAS, restated in exact integer arithmetic so that hardware and reference models agree bit for bit.

### 8.1 Adaptive amount

For each component, with the neighbourhood `a b c / d e f / g h i` (centre `e`, clamp-to-edge) and `M = 2^COMP_W − 1`:

```
mn   = min(b, d, e, f, h) + min(a … i)        soft minimum, 0 … 2M
mx   = max(b, d, e, f, h) + max(a … i)        soft maximum, 0 … 2M
head = min(mn, 2M − mx)                       distance to the nearer clipping level
amp  = head / mx                              0 … 1
```

Adding the cross-shaped and the full 3×3 extrema, as CAS does, makes the estimate less sensitive to single-pixel noise. `amp` is large where the neighbourhood has room to grow in both directions (low contrast, mid-grey), and small near black or white or across strong edges. That is what keeps the filter from creating halos and clipping.

In hardware the division uses a reciprocal ROM:

```
RECIP[v] = round(2^24 / v),  v = 1 … 2M
amp_q8   = min(256, (head · RECIP[mx] + 2^15) >> 16)      Q8; 0 when mx = 0
```

CAS then applies a square root, which lifts small amounts:

```
sq = SQRT[amp_q8] = round(16 · √amp_q8)                   Q8, 0 … 256
```

The rounding is exact integer rounding: `r = ⌊√(amp·256)⌋`, incremented if `amp·256 − r² > r`.

### 8.2 Strength from SHARPNESS

CAS uses a peak negative lobe of `−1 / lerp(8, 5, s)` with `s = SHARPNESS / 256`. Solving the CAS normalisation `(e − w·Σ) / (1 − 4w)` at full amplitude for the equivalent unsharp-mask gain gives `k_max = 1 / (4 − 3s)`, which runs from 0.25 to 1. The hardware stores it as a Q8 gain ROM indexed by SHARPNESS:

```
G[S] = round(65536 / (1024 − 3·S)),  S = 0 … 256
```

| SHARPNESS | 0 | 64 | 128 | 192 | 256 |
|---|---|---|---|---|---|
| G (Q8) | 64 | 79 | 102 | 146 | 256 |
| k_max | 0.25 | 0.31 | 0.40 | 0.57 | 1.00 |

The curve is deliberately non-linear, as in CAS. Most of the extra strength arrives in the upper third of the range.

### 8.3 Applying the filter

```
k   = (sq · G + 128) >> 8                                  Q8, 0 … 256
d   = 4e − b − d − f − h                                   Laplacian
out = clamp(e + ((k · d + 128) >>> 8), 0, M)
```

This is the unsharp-mask form of CAS. The reference shader computes `(e + w·(b+d+f+h)) / (1 + 4w)` with a per-pixel reciprocal; algebraically that equals `e + k'·d` with `k' = −w / (1 + 4w)`. The hardware uses `k = amp·k_max` instead of the exact `k'(amp)`. The two agree at `amp = 0` and at `amp = 1`, and both are monotonic in between. This removes a per-pixel divider for a mild difference in mid-range strength.

### 8.4 Worked examples (8-bit, SHARPNESS = 128 → G = 102)

| Neighbourhood | mn / mx | head | amp | sq | k | d | out |
|---|---|---|---|---|---|---|---|
| centre 120 on flat 100 (faint detail) | 200 / 240 | 200 | 213 | 234 | 93 | 80 | **149** (strong boost) |
| centre 240 on flat 20 (hard spike) | 40 / 480 | 30 | 16 | 64 | 26 | 880 | 255 (little headroom, low k) |

The second row shows the adaptivity. The contrast is eleven times larger, but the strength `k` is less than a third of the first row's.

### 8.5 Programming

Write `SIZE = {height, width}` (it must match the incoming frames) and `SHARPNESS`, clear `STATUS`, then write `CTRL = 1` (or `3` for BYPASS). SIZE, SHARPNESS and BYPASS are latched at each start of frame. Recommended values: 64–128 for natural video after upscaling, 160–256 for soft sources.

## 9. Spatial upscaler (spatial_upscaler)

`spatial_upscaler` chains `scaler_lanczos` and `sharpen_cas` behind one AXI-Lite port. Program it in three steps:

1. **Scaler** (offsets 0x0000–0x3FFF): the common registers from §1 and the Lanczos-3 tables from §5, with anti-aliasing stretch when downscaling. This is exactly the `scaler_lanczos` sequence.
2. **Sharpener** (offsets 0x4000–0x40FF): `SIZE (0x4008) = OUT_SIZE` of the scaler, then `SHARPNESS (0x4040)`, then `CTRL (0x4000) = 1`.
3. **Start** by writing the scaler `CTRL (0x0000) = 1`.

`tools/scaler_coefs.py upscaler --in W H --out W H --sharpness S` emits the whole sequence.
