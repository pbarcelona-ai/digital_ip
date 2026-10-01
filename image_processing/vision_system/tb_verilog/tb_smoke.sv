// ***************
// Filename: tb_smoke.sv
// Author: FPGA Cores 4 U
// Description: Fast SystemVerilog smoke test driving coord_gen directly
// (no frame streaming). Covers identity, radial, tangential,
// camera calibration, real fisheye/panoramic/perspective math,
// remaining hooks, and large-frame (479/719) boundary checks.
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_smoke.sv
//
// Fast SystemVerilog smoke test -- NOT the full 12-scenario image-streaming
// regression (see tb_vision_system.sv / tb/ for that). This
// drives coord_gen.sv DIRECTLY, point-by-point, against the independent
// coord_gen_ref() reference, to give a quick (seconds,
// not the multi-frame matrix's longer runtime) pass/fail signal for:
//
//   1. Legacy-equivalent config (radial, k=p=0)      -> identity round trip
//   2. Radial distortion (k1 nonzero)                -> matches golden model
//   3. Tangential distortion (p1,p2 nonzero)          -> matches golden model
//   4. Direct camera-calibration fx/fy/cx/cy (non-power-of-two pixel
//      values, not derived from IMG_WIDTH/CENTER/SCALE at all)
//   5. ARCHITECTURE HOOK gate: model_sel != MODEL_RADIAL, with NONZERO
//      k1/p1 configured, must still produce an identity round trip (the
//      hook must actually ignore the distortion coefficients, not just
//      happen to match when they're zero)
//
// Run: iverilog -g2012 -o smoke.vvp ppm_io_pkg.sv golden_model_pkg.sv \
//        ../src/barrel_pkg.sv ../src/distortion_model_pkg.sv \
//        ../src/fixed_recip.sv ../src/coord_gen.sv tb_smoke.sv && vvp smoke.vvp
// (also wired into run.sh, see below)
// =============================================================================
`timescale 1ns/1ps
import barrel_pkg::*;
import distortion_model_pkg::*;
import golden_model_pkg::coord_gen_ref;
import golden_model_pkg::recip_ref;

module tb_smoke;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  calib_params_t cfg;
  logic              in_valid;
  logic [COORD_W-1:0] in_x, in_y;
  logic               out_valid;
  logic signed [31:0] out_sx_q16, out_sy_q16;

  coord_gen dut (
    .clk, .rst_n, .cfg,
    .in_valid, .in_x, .in_y,
    .out_valid, .out_sx_q16, .out_sy_q16
  );

  int total_checks, total_fail;

  // Drives one (x,y) point through the DUT and checks it against
  // coord_gen_ref(), tolerating a small ULP-level difference from the
  // iterative reciprocal divider (same tolerance convention the rest of
  // this project's testbenches use for bit-exactness in pixel space --
  // here in Q16.16 coordinate space the DUT and reference should agree
  // far more tightly since there's no 8-bit pixel quantization involved).
  task automatic check_point(input string label, input int x, input int y);
    longint exp_sx, exp_sy;
    longint diff_x, diff_y;
    int wait_cycles;
    begin
      coord_gen_ref(cfg.cx_pix, cfg.cy_pix, cfg.fx_pix, cfg.fy_pix,
                     cfg.k1, cfg.k2, cfg.k3, cfg.p1, cfg.p2,
                     int'(cfg.model_sel),
                     cfg.h11, cfg.h12, cfg.h13, cfg.h21, cfg.h22, cfg.h23, cfg.h31, cfg.h32,
                     x, y, exp_sx, exp_sy);

      in_x <= x[COORD_W-1:0]; in_y <= y[COORD_W-1:0]; in_valid <= 1'b1;
      @(posedge clk);
      in_valid <= 1'b0;
      // Poll for out_valid rather than a fixed cycle count -- the fast
      // path (MODEL_RADIAL/AFFINE/SCALING) and the slow per-pixel-divide
      // path (MODEL_FISHEYE/PANORAMIC/PERSPECTIVE) have very different
      // latencies (9 vs. ~38 cycles), both fixed but not worth hardcoding
      // two separate wait counts into this testbench.
      wait_cycles = 0;
      while (!out_valid && wait_cycles < 100) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end

      if (!out_valid) begin
        $display("[%s] (%0d,%0d) FAIL: out_valid not asserted within timeout", label, x, y);
        total_fail = total_fail + 1;
      end else begin
        diff_x = longint'(out_sx_q16) - exp_sx; if (diff_x < 0) diff_x = -diff_x;
        diff_y = longint'(out_sy_q16) - exp_sy; if (diff_y < 0) diff_y = -diff_y;
        if (diff_x <= 4 && diff_y <= 4) begin
          $display("[%s] (%0d,%0d) PASS  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
        end else begin
          $display("[%s] (%0d,%0d) FAIL  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
          total_fail = total_fail + 1;
        end
      end
      total_checks = total_checks + 1;
      // one idle cycle between checks -- coord_gen tolerates sparse valid
      // inputs by design (same property the bicubic gather FSM's request
      // pacing relies on), so this also incidentally exercises that.
      @(posedge clk);
    end
  endtask

  initial begin
    rst_n = 0; in_valid = 0; in_x = '0; in_y = '0;
    cfg = '0;
    total_checks = 0; total_fail = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. legacy-equivalent identity (k=p=0, radial model) -----------
    cfg.cx_pix = 32'sd32 <<< 16; cfg.cy_pix = 32'sd24 <<< 16;
    cfg.fx_pix = 32'sd40 <<< 16; cfg.fy_pix = 32'sd40 <<< 16;
    cfg.recip_fx = recip_ref(cfg.fx_pix); cfg.recip_fy = recip_ref(cfg.fy_pix);
    cfg.k1 = 0; cfg.k2 = 0; cfg.k3 = 0; cfg.p1 = 0; cfg.p2 = 0;
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
    cfg.cx_pix = 32'sd37 <<< 16; cfg.cy_pix = 32'sd29 <<< 16;
    cfg.fx_pix = 32'sd53 <<< 16; cfg.fy_pix = 32'sd61 <<< 16;   // fx != fy, non-power-of-2
    cfg.recip_fx = recip_ref(cfg.fx_pix); cfg.recip_fy = recip_ref(cfg.fy_pix);
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
    cfg.h11 = 32'sh0001_199A; cfg.h12 = 32'sd3277;  cfg.h13 = -32'sd65536;
    cfg.h21 = -32'sd1638;     cfg.h22 = 32'sh0000_F333; cfg.h23 = 32'sd32768;
    cfg.h31 = 32'sd164;       cfg.h32 = -32'sd82;
    check_point("perspective",     0,  0);
    check_point("perspective",    70, 55);
    check_point("perspective",    12,  8);

    // ---- 7.5. large-frame boundary coordinates (480x480 / 480x720 /
    // 720x480 -- the sizes this project's full-pipeline testbenches were
    // scaled up to) exercised DIRECTLY against coord_gen. See
    // ip/coord_gen/tb_coord_gen.sv for the fuller rationale/comment;
    // this is the same check mirrored into the top-level smoke test.
    cfg.cx_pix = 32'sd240 <<< 16; cfg.cy_pix = 32'sd360 <<< 16;
    cfg.fx_pix = 32'sd240 <<< 16; cfg.fy_pix = 32'sd360 <<< 16;
    cfg.recip_fx = golden_model_pkg::recip_ref(cfg.fx_pix); cfg.recip_fy = golden_model_pkg::recip_ref(cfg.fy_pix);

    cfg.model_sel = MODEL_RADIAL;
    cfg.k1 = -32'sd6554; cfg.k2 = 32'sd1311; cfg.k3 = 0; cfg.p1 = 32'sd819; cfg.p2 = -32'sd819;
    check_point("large_frame_radial",       0,   0);
    check_point("large_frame_radial",     479,   0);
    check_point("large_frame_radial",       0, 719);
    check_point("large_frame_radial",     479, 719);

    cfg.model_sel = MODEL_FISHEYE;
    cfg.p1 = 0; cfg.p2 = 0;
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
    cfg.h11 = 32'sh0001_0000; cfg.h12 = 0; cfg.h13 = 0;
    cfg.h21 = 0; cfg.h22 = 32'sh0001_0000; cfg.h23 = 0;
    cfg.h31 = 32'sd26; cfg.h32 = -32'sd13;
    check_point("large_frame_perspective",  0,   0);
    check_point("large_frame_perspective",479,   0);
    check_point("large_frame_perspective",  0, 719);
    check_point("large_frame_perspective",479, 719);

    // ---- 8. remaining architecture hooks: must still ignore k1/p1/H ----
    // (k1/k2/H from the previous blocks are deliberately left nonzero here)
    cfg.model_sel = MODEL_AFFINE;
    check_point("hook_affine",    70, 55);
    cfg.model_sel = MODEL_SCALING;
    check_point("hook_scaling",   70, 55);

    $display("=== SMOKE TEST: %0d/%0d points passed ===", total_checks - total_fail, total_checks);
    if (total_fail == 0) $display(">>> SMOKE TEST PASSED <<<");
    else                 $display(">>> SMOKE TEST FAILED (%0d mismatches) <<<", total_fail);

    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_smoke);
  end
`endif
endmodule
