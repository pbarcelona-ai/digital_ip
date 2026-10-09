"""
test_vision_system.py  (cocotb testbench for vision_system)

Flow (matches the spec), run once per distortion type (barrel, pincushion):
  1. Load test.jpg or test.ppm (auto-generated if absent) -- shared
     between both scenarios.
  2. Synthesize warped_<type>.jpg/.ppm from it using the RTL's own
     fixed-point radial-remap primitive (image_io.radial_remap_fixed),
     fed a set of "distortion" k values (positive k1 = barrel, negative
     k1 = pincushion -- see README's "Sign convention" note, verified
     empirically rather than assumed).
  3. Numerically fit correction k values that approximately invert that
     distortion, and compute the bit-exact golden "corrected" image the
     RTL is expected to produce (same primitive, correction k's, applied
     to the warped image).
  4. Program the DUT over AXI4-Lite (K1/K2/K3, IMG_WIDTH/HEIGHT,
     CENTER_X/Y, SCALE), then stream the warped image in over AXI4-Stream
     with the spec's "line, then 5 idle cycles" timing, while capturing
     the AXI4-Stream output with the same timing.
  5. Save corrected_<type>.jpg/.ppm from the DUT's actual output.
  6. Self-check: (a) DUT output must match the bit-exact golden model
     pixel-for-pixel (tight tolerance, catches any RTL/arithmetic bug),
     and (b) the corrected image must be substantially closer to the
     original than the warped image was (catches algorithmic/ordering
     mistakes that a narrow bit-exact check alone might miss).

Two independent @cocotb.test() entry points below run this flow with
opposite-signed distortion coefficients, so both barrel *and* pincushion
correction are exercised -- not just one direction of the polynomial.
"""
import os
import sys
import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout

sys.path.insert(0, os.path.dirname(__file__))
import image_io as io

CLK_PERIOD_NS = 10  # 100 MHz
LINE_GAP_CYCLES = 5

REG_CTRL       = 0x00
REG_STATUS     = 0x04
REG_IMG_WIDTH  = 0x08
REG_IMG_HEIGHT = 0x0C
REG_K1         = 0x10
REG_K2         = 0x14
REG_K3         = 0x18
REG_CENTER_X   = 0x1C
REG_CENTER_Y   = 0x20
REG_SCALE      = 0x24
REG_VERSION    = 0x28
REG_INTERP_MODE= 0x2C
REG_CALIB_MODE = 0x30
REG_FX         = 0x34
REG_FY         = 0x38
REG_CX         = 0x3C
REG_CY         = 0x40
REG_P1         = 0x44
REG_P2         = 0x48
REG_MODEL_SEL  = 0x4C
REG_H11        = 0x50
REG_H12        = 0x54
REG_H13        = 0x58
REG_H21        = 0x5C
REG_H22        = 0x60
REG_H23        = 0x64
REG_H31        = 0x68
REG_H32        = 0x6C

# (kd1, kd2, kd3) synthetic-distortion coefficients. Verified empirically
# (see README): positive k1 applied to a flat image produces genuine
# barrel bulge; negative k1 produces genuine pincushion. Pincushion here
# is simply the sign-negated barrel triple -- confirmed to give
# comparable correction quality on this test chart.
DISTORTION_PARAMS = {
    "barrel":     (0.08, -0.01, 0.0),
    "pincushion": (-0.08, 0.01, 0.0),
}


def to_u32(signed_val: int) -> int:
    return signed_val & 0xFFFFFFFF


async def axil_write(dut, addr, data):
    dut.s_axil_awaddr.value = addr
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wdata.value = to_u32(data)
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_wvalid.value = 1
    await RisingEdge(dut.clk)
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wvalid.value = 0
    for _ in range(100):
        if dut.s_axil_bvalid.value == 1:
            break
        await RisingEdge(dut.clk)
    dut.s_axil_bready.value = 1
    await RisingEdge(dut.clk)
    dut.s_axil_bready.value = 0


async def axil_read(dut, addr) -> int:
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    await RisingEdge(dut.clk)
    dut.s_axil_arvalid.value = 0
    for _ in range(100):
        if dut.s_axil_rvalid.value == 1:
            break
        await RisingEdge(dut.clk)
    data = int(dut.s_axil_rdata.value)
    dut.s_axil_rready.value = 1
    await RisingEdge(dut.clk)
    dut.s_axil_rready.value = 0
    return data


def pack_pixel(rgb) -> int:
    r, g, b = int(rgb[0]), int(rgb[1]), int(rgb[2])
    return (r << 16) | (g << 8) | b


def unpack_pixel(word: int):
    return ((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF)


async def init_signals(dut):
    dut.rst_n.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_axis_tready.value = 1
    dut.s_axil_awaddr.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value = 0
    dut.s_axil_wstrb.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_araddr.value = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 0


async def stream_frame_in(dut, img: np.ndarray):
    h, w = img.shape[0], img.shape[1]
    for y in range(h):
        for x in range(w):
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tdata.value = pack_pixel(img[y, x])
            dut.s_axis_tlast.value = 1 if (x == w - 1) else 0
            dut.s_axis_tuser.value = 1 if (x == 0 and y == 0) else 0
            await RisingEdge(dut.clk)
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tuser.value = 0
        await ClockCycles(dut.clk, LINE_GAP_CYCLES)


async def capture_frame_out(dut, w: int, h: int) -> np.ndarray:
    out = np.zeros((h, w, 3), dtype=np.uint8)
    count = 0
    total = w * h
    saw_first_tuser = False
    while count < total:
        await RisingEdge(dut.clk)
        if dut.m_axis_tvalid.value == 1 and dut.m_axis_tready.value == 1:
            y, x = count // w, count % w
            word = int(dut.m_axis_tdata.value)
            out[y, x] = unpack_pixel(word)
            expect_tlast = (x == w - 1)
            if bool(dut.m_axis_tlast.value) != expect_tlast:
                raise AssertionError(
                    f"m_axis_tlast mismatch at pixel {count} (x={x},y={y}): "
                    f"got {bool(dut.m_axis_tlast.value)}, expected {expect_tlast}")
            if count == 0:
                saw_first_tuser = bool(dut.m_axis_tuser.value)
            count += 1
    if not saw_first_tuser:
        raise AssertionError("m_axis_tuser was not asserted on the first output pixel")
    return out


async def run_one_frame(dut, label: str, src: np.ndarray, test_path: str,
                         kd1_q: int, kd2_q: int, kd3_q: int,
                         kc1_q: int, kc2_q: int, kc3_q: int, interp_mode: int):
    """Synthesizes a warped_<label>.* from src (BILINEAR forward remap
    always -- synthesizing the distorted stimulus is independent of which
    interpolation mode the DUT is about to be tested in), computes the
    bit-exact golden CORRECTED reference using whichever interpolation
    mode is currently under test (mirrors the DUT's own selected mode),
    programs IMG_WIDTH/IMG_HEIGHT for this frame's own shape, streams it
    through the already-configured DUT, captures the output, and runs
    the self-checks. Does NOT reset the DUT and does NOT rewrite
    K1/K2/K3 or INTERP_MODE -- those are set once per group by
    run_group() below, so calling this repeatedly exercises the
    back-to-back consecutive-frame path (with image SIZE changing
    between frames, on top of the distortion-type/interp-mode changes
    covered between groups)."""
    h, w = src.shape[0], src.shape[1]
    cx_q, cy_q, sc_q = io.to_q16(0.5), io.to_q16(0.5), io.to_q16(1.0)
    cfg = io.RemapConfig(w, h, cx_q, cy_q, sc_q)

    warped = io.radial_remap_fixed(src, cfg, kd1_q, kd2_q, kd3_q)
    warped_path = io.sibling_path(test_path, f"warped_{label}")
    io.write_image(warped_path, warped)

    if interp_mode:
        golden = io.radial_remap_bicubic_fixed(warped, cfg, kc1_q, kc2_q, kc3_q)
    else:
        golden = io.radial_remap_fixed(warped, cfg, kc1_q, kc2_q, kc3_q)

    await axil_write(dut, REG_IMG_WIDTH, w)
    await axil_write(dut, REG_IMG_HEIGHT, h)

    for _ in range(200):
        status = await axil_read(dut, REG_STATUS)
        if (status & 0x4) == 0:   # recip_busy clear
            break
        await ClockCycles(dut.clk, 1)
    else:
        raise AssertionError(f"[{label}] timed out waiting for recip_busy to clear")

    out_task = cocotb.start_soon(capture_frame_out(dut, w, h))
    await stream_frame_in(dut, warped)
    dut_out = await with_timeout(out_task, 4_000_000, "ns")

    corrected_path = io.sibling_path(test_path, f"corrected_{label}")
    io.write_image(corrected_path, dut_out)

    diff = np.abs(dut_out.astype(int) - golden.astype(int))
    max_err = int(diff.max())
    n_mismatch = int((diff > 1).sum())
    dut._log.info(f"[{label}] DUT vs golden model: max_err={max_err} pixels_off_by_>1={n_mismatch}/{diff.size}")

    mae_warp_vs_orig = float(np.abs(warped.astype(int) - src.astype(int)).mean())
    mae_corr_vs_orig = float(np.abs(dut_out.astype(int) - src.astype(int)).mean())
    dut._log.info(f"[{label}] MAE(warped, original)       = {mae_warp_vs_orig:.3f}")
    dut._log.info(f"[{label}] MAE(DUT-corrected, original) = {mae_corr_vs_orig:.3f}")

    ok_bitexact = (n_mismatch == 0) and (max_err <= 1)
    # Heuristic sanity check only (the bit-exact check above is the real
    # correctness gate) -- 0.85 rather than a tighter ratio because the
    # smaller per-shape test images used here show less dramatic relative
    # improvement than a single larger test chart would.
    ok_quality = mae_corr_vs_orig < 0.85 * mae_warp_vs_orig

    dut._log.info(f"[{label}] SELF-CHECK bit-exact-vs-golden : {'PASS' if ok_bitexact else 'FAIL'}")
    dut._log.info(f"[{label}] SELF-CHECK correction-quality  : {'PASS' if ok_quality else 'FAIL'}")

    if not ok_bitexact:
        raise AssertionError(
            f"[{label}] DUT output does not match golden fixed-point model "
            f"(max_err={max_err}, {n_mismatch} pixels off by >1 LSB)")
    if not ok_quality:
        raise AssertionError(
            f"[{label}] corrected image is not meaningfully closer to the "
            f"original than the warped image (corr MAE={mae_corr_vs_orig:.2f}, "
            f"warp MAE={mae_warp_vs_orig:.2f})")


async def run_group(dut, dist_label: str, kd1f: float, kd2f: float, kd3f: float,
                     interp_mode: int, mode_label: str, shapes):
    """One distortion x interp-mode group: 3 CONSECUTIVE frames (square,
    portrait, landscape -- no reset between them), continuing to exercise
    the back-to-back-frame path (bug #4) with image DIMENSIONS now
    changing between consecutive frames too, on top of size being read
    from each test image rather than hardcoded. `shapes` is a list of
    (shape_label, src_array, test_path) triples."""
    dut._log.info(f"=== group: {dist_label} / {mode_label} (kd1={kd1f}, kd2={kd2f}, kd3={kd3f}) ===")
    kd1_q, kd2_q, kd3_q = io.to_q16(kd1f), io.to_q16(kd2f), io.to_q16(kd3f)
    kc1f, kc2f, kc3f = io.fit_correction_coeffs(kd1_q, kd2_q, kd3_q)
    kc1_q, kc2_q, kc3_q = io.to_q16(kc1f), io.to_q16(kc2f), io.to_q16(kc3f)
    dut._log.info(f"correction coeffs (Q16.16): k1={kc1_q} k2={kc2_q} k3={kc3_q}")

    await axil_write(dut, REG_INTERP_MODE, interp_mode)
    await axil_write(dut, REG_K1, kc1_q)
    await axil_write(dut, REG_K2, kc2_q)
    await axil_write(dut, REG_K3, kc3_q)
    await axil_write(dut, REG_CENTER_X, io.to_q16(0.5))
    await axil_write(dut, REG_CENTER_Y, io.to_q16(0.5))
    await axil_write(dut, REG_SCALE, io.to_q16(1.0))

    for shape_label, src, test_path in shapes:
        label = f"{dist_label}_{mode_label}_{shape_label}"
        await run_one_frame(dut, label, src, test_path,
                             kd1_q, kd2_q, kd3_q, kc1_q, kc2_q, kc3_q, interp_mode)


async def run_distortion_matrix(dut, distortion_type: str, shapes):
    """Runs BOTH interpolation modes (bilinear, bicubic) for one
    distortion type, each as 3 consecutive frames across the three
    shapes -- i.e. 6 consecutive frames total per distortion type, all
    within the one already-reset simulation this test entry point owns."""
    kd1f, kd2f, kd3f = DISTORTION_PARAMS[distortion_type]
    await run_group(dut, distortion_type, kd1f, kd2f, kd3f, 0, "bilinear", shapes)
    await run_group(dut, distortion_type, kd1f, kd2f, kd3f, 1, "bicubic", shapes)


async def run_division_model_correction_test(dut, label: str, model_sel_val: int,
                                               kd1f: float, kd2f: float,
                                               src: np.ndarray, test_path: str):
    """Synthesizes a genuinely fisheye/panoramic-DISTORTED image by
    applying the division model once (forward, kd1/kd2) to a flat source
    image via full_remap_ref, fits a correction (kc1/kc2) via
    fit_division_model_coeffs (a grid search, not a closed-form inverse
    -- the division model isn't linear in its coefficients), applies
    that correction through the ACTUAL DUT, and checks both bit-
    exactness against the golden model and a genuine MAE improvement --
    the exact same evidentiary standard the barrel/pincushion (radial)
    tests are held to, not merely "the hook was a no-op". Mirrors
    tb_verilog/tb_vision_system.sv's
    run_division_model_correction_test."""
    h, w = src.shape[0], src.shape[1]
    dut._log.info(f"=== {label} correction test (MODEL_SEL={model_sel_val}, {w}x{h}, "
                   f"kd1={kd1f} kd2={kd2f}) ===")
    kd1_q, kd2_q = io.to_q16(kd1f), io.to_q16(kd2f)
    cfg = io.RemapConfig(w, h, io.to_q16(0.5), io.to_q16(0.5), io.to_q16(1.0))

    warped = io.full_remap_ref(cfg, model_sel_val, kd1_q, kd2_q, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0, src)
    warped_path = io.sibling_path(test_path, f"warped_{label}")
    io.write_image(warped_path, warped)

    kc1_q, kc2_q = io.fit_division_model_coeffs(cfg, model_sel_val, warped, src)
    dut._log.info(f"[{label}] fitted correction coeffs (Q16.16): kc1={kc1_q} kc2={kc2_q}")

    golden = io.full_remap_ref(cfg, model_sel_val, kc1_q, kc2_q, 0, 0, 0,
                                0, 0, 0, 0, 0, 0, 0, 0, warped)

    await axil_write(dut, REG_MODEL_SEL, model_sel_val)
    await axil_write(dut, REG_INTERP_MODE, 0)
    await axil_write(dut, REG_K1, kc1_q)
    await axil_write(dut, REG_K2, kc2_q)
    await axil_write(dut, REG_K3, 0)
    await axil_write(dut, REG_P1, 0)
    await axil_write(dut, REG_P2, 0)
    await axil_write(dut, REG_CENTER_X, io.to_q16(0.5))
    await axil_write(dut, REG_CENTER_Y, io.to_q16(0.5))
    await axil_write(dut, REG_SCALE, io.to_q16(1.0))
    await axil_write(dut, REG_IMG_WIDTH, w)
    await axil_write(dut, REG_IMG_HEIGHT, h)

    for _ in range(200):
        status = await axil_read(dut, REG_STATUS)
        if (status & 0x4) == 0:
            break
        await ClockCycles(dut.clk, 1)
    else:
        raise AssertionError(f"[{label}] timed out waiting for recip_busy to clear")

    out_task = cocotb.start_soon(capture_frame_out(dut, w, h))
    await stream_frame_in(dut, warped)
    dut_out = await with_timeout(out_task, 4_000_000, "ns")

    corrected_path = io.sibling_path(test_path, f"corrected_{label}")
    io.write_image(corrected_path, dut_out)

    diff = np.abs(dut_out.astype(int) - golden.astype(int))
    max_err = int(diff.max())
    n_mismatch = int((diff > 1).sum())
    mae_warp = float(np.abs(warped.astype(int) - src.astype(int)).mean())
    mae_corr = float(np.abs(dut_out.astype(int) - src.astype(int)).mean())
    dut._log.info(f"[{label}] DUT vs golden model: max_err={max_err} pixels_off_by_>1={n_mismatch}/{diff.size}")
    dut._log.info(f"[{label}] MAE(warped, original)       = {mae_warp:.3f}")
    dut._log.info(f"[{label}] MAE(DUT-corrected, original) = {mae_corr:.3f}")

    ok_bitexact = (n_mismatch == 0) and (max_err <= 1)
    ok_quality = mae_corr < 0.85 * mae_warp

    dut._log.info(f"[{label}] SELF-CHECK bit-exact-vs-golden : {'PASS' if ok_bitexact else 'FAIL'}")
    dut._log.info(f"[{label}] SELF-CHECK correction-quality  : {'PASS' if ok_quality else 'FAIL'}")

    if not ok_bitexact:
        raise AssertionError(
            f"[{label}] DUT output does not match golden fixed-point model "
            f"(max_err={max_err}, {n_mismatch} pixels off by >1 LSB)")
    if not ok_quality:
        raise AssertionError(
            f"[{label}] corrected image is not meaningfully closer to the "
            f"original than the warped image (corr MAE={mae_corr:.2f}, warp MAE={mae_warp:.2f})")

    await axil_write(dut, REG_MODEL_SEL, 0)


async def run_perspective_correction_test(dut, label: str, src: np.ndarray, test_path: str):
    """Synthesizes a genuinely keystone-distorted image with a KNOWN
    forward homography, computes its EXACT inverse in closed form
    (invert_homography -- unlike the division model, a homography's
    correction is not approximate), applies that correction through the
    DUT, and checks both bit-exactness and a genuine MAE improvement.
    Mirrors tb_verilog/tb_vision_system.sv's
    run_perspective_correction_test."""
    h, w = src.shape[0], src.shape[1]
    dut._log.info(f"=== {label} correction test ({w}x{h}) ===")

    # Mild keystone: a small x/y-dependent foreshortening (h31,h32),
    # operating directly on pixel coordinates per this design's
    # convention (see distortion_model_pkg.sv). These coefficients must
    # be scaled to the actual frame width: h31/h32 act directly on pixel
    # coordinates, so a coefficient chosen for a much smaller test image
    # can put the CORRECTED homography's denominator zero-crossing (a
    # genuine mathematical singularity, not an RTL bug) inside a much
    # larger frame -- found exactly this way in the SystemVerilog
    # testbench when it was scaled up to 720x480 (see
    # tb_verilog/tb_vision_system.sv's comment on this same
    # constant for the full account). These values keep the zero-crossing
    # far outside any frame size this project's testbenches use (~5000,
    # vs. a maximum frame dimension of 720).
    hf11, hf12, hf13 = 1.0, 0.0, 0.0
    hf21, hf22, hf23 = 0.0, 1.0, 0.0
    # Scaled to the frame (0.144/W, -0.06/H): equals 0.0002/-0.000125 at
    # 720x480 and keeps the corrected homography's zero-crossing ~7x
    # beyond the frame at ANY size (see the SystemVerilog testbench).
    hf31, hf32 = 0.144 / w, -0.06 / h

    hc11, hc12, hc13, hc21, hc22, hc23, hc31, hc32 = io.invert_homography(
        hf11, hf12, hf13, hf21, hf22, hf23, hf31, hf32)
    dut._log.info(f"[{label}] forward H31={hf31} H32={hf32} -> correcting H31={hc31:.6f} H32={hc32:.6f}")

    hfq = [io.to_q16(v) for v in (hf11, hf12, hf13, hf21, hf22, hf23, hf31, hf32)]
    hcq = [io.to_q16(v) for v in (hc11, hc12, hc13, hc21, hc22, hc23, hc31, hc32)]

    cfg = io.RemapConfig(w, h, io.to_q16(0.5), io.to_q16(0.5), io.to_q16(1.0))
    warped = io.full_remap_ref(cfg, 3, 0, 0, 0, 0, 0, *hfq, src)
    warped_path = io.sibling_path(test_path, f"warped_{label}")
    io.write_image(warped_path, warped)

    golden = io.full_remap_ref(cfg, 3, 0, 0, 0, 0, 0, *hcq, warped)

    await axil_write(dut, REG_MODEL_SEL, 3)
    await axil_write(dut, REG_INTERP_MODE, 0)
    await axil_write(dut, REG_H11, hcq[0]); await axil_write(dut, REG_H12, hcq[1]); await axil_write(dut, REG_H13, hcq[2])
    await axil_write(dut, REG_H21, hcq[3]); await axil_write(dut, REG_H22, hcq[4]); await axil_write(dut, REG_H23, hcq[5])
    await axil_write(dut, REG_H31, hcq[6]); await axil_write(dut, REG_H32, hcq[7])
    await axil_write(dut, REG_CENTER_X, io.to_q16(0.5))
    await axil_write(dut, REG_CENTER_Y, io.to_q16(0.5))
    await axil_write(dut, REG_SCALE, io.to_q16(1.0))
    await axil_write(dut, REG_IMG_WIDTH, w)
    await axil_write(dut, REG_IMG_HEIGHT, h)

    for _ in range(200):
        status = await axil_read(dut, REG_STATUS)
        if (status & 0x4) == 0:
            break
        await ClockCycles(dut.clk, 1)
    else:
        raise AssertionError(f"[{label}] timed out waiting for recip_busy to clear")

    out_task = cocotb.start_soon(capture_frame_out(dut, w, h))
    await stream_frame_in(dut, warped)
    dut_out = await with_timeout(out_task, 4_000_000, "ns")

    corrected_path = io.sibling_path(test_path, f"corrected_{label}")
    io.write_image(corrected_path, dut_out)

    diff = np.abs(dut_out.astype(int) - golden.astype(int))
    max_err = int(diff.max())
    n_mismatch = int((diff > 1).sum())
    mae_warp = float(np.abs(warped.astype(int) - src.astype(int)).mean())
    mae_corr = float(np.abs(dut_out.astype(int) - src.astype(int)).mean())
    dut._log.info(f"[{label}] DUT vs golden model: max_err={max_err} pixels_off_by_>1={n_mismatch}/{diff.size}")
    dut._log.info(f"[{label}] MAE(warped, original)       = {mae_warp:.3f}")
    dut._log.info(f"[{label}] MAE(DUT-corrected, original) = {mae_corr:.3f}")

    ok_bitexact = (n_mismatch == 0) and (max_err <= 1)
    ok_quality = mae_corr < 0.85 * mae_warp

    dut._log.info(f"[{label}] SELF-CHECK bit-exact-vs-golden : {'PASS' if ok_bitexact else 'FAIL'}")
    dut._log.info(f"[{label}] SELF-CHECK correction-quality  : {'PASS' if ok_quality else 'FAIL'}")

    if not ok_bitexact:
        raise AssertionError(
            f"[{label}] DUT output does not match golden fixed-point model "
            f"(max_err={max_err}, {n_mismatch} pixels off by >1 LSB)")
    if not ok_quality:
        raise AssertionError(
            f"[{label}] corrected image is not meaningfully closer to the "
            f"original than the warped image (corr MAE={mae_corr:.2f}, warp MAE={mae_warp:.2f})")

    await axil_write(dut, REG_MODEL_SEL, 0)
    await axil_write(dut, REG_H11, io.to_q16(1.0)); await axil_write(dut, REG_H12, 0); await axil_write(dut, REG_H13, 0)
    await axil_write(dut, REG_H21, 0); await axil_write(dut, REG_H22, io.to_q16(1.0)); await axil_write(dut, REG_H23, 0)
    await axil_write(dut, REG_H31, 0); await axil_write(dut, REG_H32, 0)


async def setup_dut(dut):
    """Clock + reset, common to every test entry point."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await init_signals(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


def load_or_make_shaped_images(dut):
    """Three test-image shapes (square, portrait, landscape), sizes read
    from the actual generated/loaded images (not hardcoded into the
    scenario logic) -- IMG_WIDTH/IMG_HEIGHT are programmed per-frame from
    these. Reuses io.make_synthetic_chart/load_image; files are cached
    under work/ across test entry points."""
    work_dir = os.path.join(os.path.dirname(__file__), "work")
    os.makedirs(work_dir, exist_ok=True)
    shapes = []
    # SMALL_FRAMES=1 selects small frames (fast; used by CI); default is the
    # full-size 480x480 / 480x720 / 720x480 set.
    if os.environ.get("SMALL_FRAMES", "0") == "1":
        shape_dims = (("square", 48, 48), ("portrait", 32, 56), ("landscape", 56, 32))
    else:
        shape_dims = (("square", 480, 480), ("portrait", 480, 720), ("landscape", 720, 480))
    for shape_label, w, h in shape_dims:
        path = os.path.join(work_dir, f"test_{shape_label}.ppm")
        if not os.path.exists(path):
            io.make_synthetic_chart(path, w, h)
        src = io.load_image(path)
        dut._log.info(f"test image [{shape_label}]: {path}  size={src.shape[1]}x{src.shape[0]}")
        shapes.append((shape_label, src, path))
    return shapes


@cocotb.test()
async def test_barrel_distortion_correction(dut):
    """Synthesizes genuine barrel-distorted images (positive k1) at three
    shapes (square/portrait/landscape) and verifies the DUT corrects them
    with BOTH interpolation modes (bilinear, then bicubic -- 6 total
    consecutive frames, no reset between them), each checked bit-exactly
    against its own golden model and by a real image-quality improvement."""
    await setup_dut(dut)
    shapes = load_or_make_shaped_images(dut)
    await run_distortion_matrix(dut, "barrel", shapes)
    # let the last register write settle before the test returns: a write still pending at
    # the end of the final test makes Icarus call back into the finalized cocotb (SIGSEGV)
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_pincushion_distortion_correction(dut):
    """Synthesizes genuine pincushion-distorted images (negative k1) at
    three shapes and verifies the DUT corrects them with BOTH
    interpolation modes, exactly as test_barrel_distortion_correction
    does. The DUT is reset again first so this scenario doesn't depend
    on the barrel test having run (each cocotb test gets a fresh
    simulation)."""
    await setup_dut(dut)
    shapes = load_or_make_shaped_images(dut)
    await run_distortion_matrix(dut, "pincushion", shapes)
    # let the last register write settle before the test returns: a write still pending at
    # the end of the final test makes Icarus call back into the finalized cocotb (SIGSEGV)
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_fisheye_panoramic_perspective_correction(dut):
    """Runs genuine fisheye, panoramic, and perspective distortion
    CORRECTION tests -- synthesize a real distorted image, fit or exactly
    compute correcting coefficients, stream through the actual DUT, check
    bit-exactness and a real MAE improvement -- the same evidentiary
    standard test_barrel_distortion_correction/
    test_pincushion_distortion_correction are held to. Run back-to-back
    (no reset between them), continuing to exercise the back-to-back-
    frame path with MODEL_SEL itself changing between consecutive
    frames, and (for fisheye/panoramic) coord_gen's per-pixel-divide
    "slow path" under real back-to-back-frame conditions. Mirrors
    tb_verilog/tb_vision_system.sv's three correction tests."""
    await setup_dut(dut)
    shapes = load_or_make_shaped_images(dut)
    sq, pt, ls = shapes[0], shapes[1], shapes[2]
    await run_division_model_correction_test(dut, "fisheye",   1, -0.20, 0.03, sq[1], sq[2])
    await run_division_model_correction_test(dut, "panoramic", 5, -0.20, 0.0,  pt[1], pt[2])
    await run_perspective_correction_test(dut, "perspective", ls[1], ls[2])
    # let the last register write settle before the test returns: a write still pending at
    # the end of the final test makes Icarus call back into the finalized cocotb (SIGSEGV)
    await ClockCycles(dut.clk, 1)

