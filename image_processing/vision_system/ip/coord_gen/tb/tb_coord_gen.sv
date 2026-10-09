// ***************
// Filename: tb_coord_gen.sv
// Author: FPGA Cores 4 U
// Description: Self-checking standalone testbench for coord_gen, with
// its own inline golden reference. Covers identity, radial,
// tangential, camera calibration, real fisheye/panoramic/
// perspective math, remaining hooks, and large-frame boundary
// coordinates (479/719).
//   The test tasks are in tests/coord_gen_tests.sv (`included).
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_coord_gen.sv
//
// Self-checking testbench for coord_gen.sv (reusable IP). Depends on
// barrel_pkg.sv (Q16.16 format, qmul) and distortion_model_pkg.sv (the
// calib_params_t struct / distortion_model_e enum) -- this IP's two
// package dependencies, both in ../../src/, this project's shared
// package location.
//
// The golden reference (coord_gen_ref/recip_ref below) is written FRESH,
// inline, in this file -- deliberately NOT reusing tb_verilog/
// golden_model_pkg.sv's identically-named functions, so this IP
// directory is fully self-contained and can be lifted into another
// project without needing anything from tb_verilog/. (The duplication
// this implies is intentional, not an oversight -- see this project's
// README for the "independent implementation" verification philosophy
// this follows throughout.)
//
// Covers the same five scenarios as the top-level project's smoke test
// (tb_verilog/tb_smoke.sv), at the coord_gen level directly:
//   1. legacy-equivalent identity (k=p=0, MODEL_RADIAL)
//   2. radial distortion (k1 nonzero)
//   3. tangential distortion (p1,p2 nonzero)
//   4. direct camera-calibration fx/fy/cx/cy (non-power-of-two, fx!=fy)
//   5. architecture-hook gate: model_sel != MODEL_RADIAL must ignore
//      nonzero k1/p1 and produce a near-identity round trip
// =============================================================================
`timescale 1ns/1ps
import barrel_pkg::*;
import distortion_model_pkg::*;

module tb_coord_gen;

  // ---- independent golden reference (fresh, not shared with the RTL) ---
  function automatic longint recip_ref(input longint operand);
    longint op, q;
    begin
      op = (operand <= 0) ? 1 : operand;
      q = (64'sh1_0000_0000) / op;
      if (q > 64'sh0000_0000_FFFF_FFFF) q = 64'sh0000_0000_FFFF_FFFF;
      recip_ref = q;
    end
  endfunction

  function automatic longint qmul_ref(input longint a, input longint b);
    longint prod;
    begin
      prod = (a * b) >>> FRAC_BITS;
      if (prod > 64'sh0000_0000_7FFF_FFFF) prod = 64'sh0000_0000_7FFF_FFFF;
      if (prod < -64'sh0000_0000_8000_0000) prod = -64'sh0000_0000_8000_0000;
      qmul_ref = prod;
    end
  endfunction

  localparam longint ONE_Q16 = 32'h0001_0000;

  // ---- DUT ---------------------------------------------------------------
  logic clk = 0, rst_n = 0;
  calib_params_t cfg;
  logic              in_valid;
  logic [COORD_W-1:0] in_x, in_y;
  logic               out_valid;
  logic signed [31:0] out_sx_q16, out_sy_q16;

  coord_gen dut (
    .clk,
    .rst_n,
    .cfg,
    .in_valid,
    .in_x,
    .in_y,
    .out_valid,
    .out_sx_q16,
    .out_sy_q16
  );

  localparam int COORD_GEN_LATENCY = 23;  // coord_gen.sv's documented pipeline depth

  always #5 clk = ~clk;

  int total_checks, total_fail;

  // test tasks: tests/coord_gen_tests.sv
  `include "coord_gen_tests.sv"

  initial begin
    rst_n = 0;
    in_valid = 0;
    in_x = '0;
    in_y = '0;
    cfg = '0;
    total_checks = 0;
    total_fail = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. legacy-equivalent identity (k=p=0, radial model) -----------
    cfg.cx_pix = 32'sd32 <<< 16;
    cfg.cy_pix = 32'sd24 <<< 16;
    cfg.fx_pix = 32'sd40 <<< 16;
    cfg.fy_pix = 32'sd40 <<< 16;
    cfg.recip_fx = recip_ref(cfg.fx_pix);
    cfg.recip_fy = recip_ref(cfg.fy_pix);
    cfg.k1 = 0;
    cfg.k2 = 0;
    cfg.k3 = 0;
    cfg.p1 = 0;
    cfg.p2 = 0;
    cfg.model_sel = MODEL_RADIAL;
    check_point("identity",        0,  0);
    check_point("identity",       50, 30);
    check_point("identity",       63, 47);

    // ---- 2. radial distortion (k1 nonzero) ------------------------------
    cfg.k1 = -32'sd9830; // ~ -0.15 in Q16.16
    check_point("radial_k1",       0,  0);
    check_point("radial_k1",      50, 30);
    check_point("radial_k1",      10, 40);

    // ---- 3. tangential distortion (p1,p2 nonzero, k back to 0) ----------
    cfg.k1 = 0;
    cfg.p1 = 32'sd3277;  // ~0.05
    cfg.p2 = -32'sd1638; // ~-0.025
    check_point("tangential",      0,  0);
    check_point("tangential",     50, 30);
    check_point("tangential",     10, 40);

    // ---- 4. direct camera-calibration fx/fy/cx/cy, non-power-of-two ----
    cfg.cx_pix = 32'sd37 <<< 16;
    cfg.cy_pix = 32'sd29 <<< 16;
    cfg.fx_pix = 32'sd53 <<< 16; // fx != fy, non-power-of-2
    cfg.fy_pix = 32'sd61 <<< 16;
    cfg.recip_fx = recip_ref(cfg.fx_pix);
    cfg.recip_fy = recip_ref(cfg.fy_pix);
    cfg.k1 = -32'sd6554; // ~-0.1
    cfg.p1 = 32'sd1638;  // ~0.025
    check_point("camera_calib",    0,  0);
    check_point("camera_calib",   70, 55);
    check_point("camera_calib",   12,  8);

    // ---- 5. REAL fisheye (division model, k1/k2 reused) ----------------
    cfg.model_sel = MODEL_FISHEYE;
    cfg.k1 = -32'sd6554;  // ~-0.1
    cfg.k2 = 32'sd1638;   // ~0.025
    check_point("fisheye",         0,  0);
    check_point("fisheye",        70, 55);
    check_point("fisheye",        12,  8);

    // ---- 6. REAL panoramic (division model, horizontal only, k1 reused) --
    cfg.model_sel = MODEL_PANORAMIC;
    check_point("panoramic",       0,  0);
    check_point("panoramic",      70, 55);

    // ---- 7. REAL perspective (3x3 homography) ---------------------------
    cfg.model_sel = MODEL_PERSPECTIVE;
    cfg.h11 = 32'sh0001_199A;
    cfg.h12 = 32'sd3277;
    cfg.h13 = -32'sd65536;
    cfg.h21 = -32'sd1638;
    cfg.h22 = 32'sh0000_F333;
    cfg.h23 = 32'sd32768;
    cfg.h31 = 32'sd164;
    cfg.h32 = -32'sd82;
    check_point("perspective",     0,  0);
    check_point("perspective",    70, 55);
    check_point("perspective",    12,  8);

    // ---- 7.5. large-frame boundary coordinates (480x480 / 480x720 /
    // 720x480 -- the sizes this project's full-pipeline testbenches were
    // scaled up to) exercised DIRECTLY against coord_gen, independent of
    // streaming a full multi-hundred-thousand-pixel frame through the
    // complete pipeline (which the slow per-pixel-divide models cannot
    // do within a practical simulation budget -- see README). This is
    // the fast, targeted way to check that COORD_W and the Q16.16
    // arithmetic throughout coord_gen's datapath stay correct at the
    // actual maximum coordinates these frame sizes need (479 and 719),
    // not just the small (<100) coordinates every other check above
    // uses. Directly caught a real bug: MAX_W/MAX_H were 512, too small
    // for a 720-pixel dimension -- see barrel_pkg.sv and README.
    cfg.cx_pix = 32'sd240 <<< 16;
    cfg.cy_pix = 32'sd360 <<< 16;
    cfg.fx_pix = 32'sd240 <<< 16;
    cfg.fy_pix = 32'sd360 <<< 16;
    cfg.recip_fx = recip_ref(cfg.fx_pix);
    cfg.recip_fy = recip_ref(cfg.fy_pix);

    cfg.model_sel = MODEL_RADIAL;
    cfg.k1 = -32'sd6554;
    cfg.k2 = 32'sd1311;
    cfg.k3 = 0;
    cfg.p1 = 32'sd819;
    cfg.p2 = -32'sd819;
    check_point("large_frame_radial",       0,   0);
    check_point("large_frame_radial",     479,   0);
    check_point("large_frame_radial",       0, 719);
    check_point("large_frame_radial",     479, 719);
    check_point("large_frame_radial",     240, 360);

    cfg.model_sel = MODEL_FISHEYE;
    cfg.p1 = 0;
    cfg.p2 = 0;
    check_point("large_frame_fisheye",      0,   0);
    check_point("large_frame_fisheye",    479,   0);
    check_point("large_frame_fisheye",      0, 719);
    check_point("large_frame_fisheye",    479, 719);

    cfg.model_sel = MODEL_PANORAMIC;
    check_point("large_frame_panoramic",    0,   0);
    check_point("large_frame_panoramic",  479,   0);
    check_point("large_frame_panoramic",    0, 719);
    check_point("large_frame_panoramic",  479, 719);

    cfg.model_sel = MODEL_PERSPECTIVE;
    cfg.h11 = 32'sh0001_0000;
    cfg.h12 = 0;
    cfg.h13 = 0;
    cfg.h21 = 0;
    cfg.h22 = 32'sh0001_0000;
    cfg.h23 = 0;
    cfg.h31 = 32'sd26; // small keystone, same order as the full-scale test
    cfg.h32 = -32'sd13;
    check_point("large_frame_perspective",  0,   0);
    check_point("large_frame_perspective",479,   0);
    check_point("large_frame_perspective",  0, 719);
    check_point("large_frame_perspective",479, 719);

    // ---- 8. remaining architecture hooks: must still ignore k1/p1/H ----
    cfg.model_sel = MODEL_AFFINE;
    check_point("hook_affine",    70, 55);
    cfg.model_sel = MODEL_SCALING;
    check_point("hook_scaling",   70, 55);

    $display("=== coord_gen self-check: %0d/%0d points passed ===", total_checks - total_fail, total_checks);
    if (total_fail == 0) $display(">>> PASS <<<");
    else                 $display(">>> FAIL (%0d mismatches) <<<", total_fail);

    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_coord_gen);
  end
`endif
endmodule
