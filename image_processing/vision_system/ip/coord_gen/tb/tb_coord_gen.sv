// ***************
// Filename: tb_coord_gen.sv
// Author: FPGA Cores 4 U
// Description: Self-checking standalone testbench for coord_gen, with
// its own inline golden reference. Covers identity, radial,
// tangential, camera calibration, real fisheye/panoramic/
// perspective math, remaining hooks, and large-frame boundary
// coordinates (479/719).
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
  task automatic coord_gen_ref(
    input  longint cx_pix, input longint cy_pix,
    input  longint fx_pix, input longint fy_pix,
    input  longint k1, input longint k2, input longint k3,
    input  longint p1, input longint p2,
    input  int     model_sel,
    input  longint h11, input longint h12, input longint h13,
    input  longint h21, input longint h22, input longint h23,
    input  longint h31, input longint h32,
    input  int     x, input int y,
    output longint sx, output longint sy
  );
    longint dx, dy, nx, ny, recip_fx, recip_fy;
    longint r2, r4, r6, t1, t2, t3, factor;
    longint tangx, tangy, sxn, syn;
    longint denom_raw, denom_safe, recip_denom;
    longint xq, yq, num_x, num_y;
    begin
      recip_fx = recip_ref(fx_pix);
      recip_fy = recip_ref(fy_pix);
      dx = (longint'(x) <<< FRAC_BITS) - cx_pix;
      dy = (longint'(y) <<< FRAC_BITS) - cy_pix;
      nx = qmul_ref(dx, recip_fx);
      ny = qmul_ref(dy, recip_fy);
      r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);

      if (model_sel == 0) begin  // MODEL_RADIAL
        r4 = qmul_ref(r2, r2);
        r6 = qmul_ref(r4, r2);
        t1 = qmul_ref(k1, r2);
        t2 = qmul_ref(k2, r4);
        t3 = qmul_ref(k3, r6);
        factor = ONE_Q16 + t1 + t2 + t3;
        tangx = (qmul_ref(p1, qmul_ref(nx, ny)) <<< 1) + qmul_ref(p2, r2 + (qmul_ref(nx, nx) <<< 1));
        tangy = qmul_ref(p1, r2 + (qmul_ref(ny, ny) <<< 1)) + (qmul_ref(p2, qmul_ref(nx, ny)) <<< 1);
        sxn = qmul_ref(nx, factor) + tangx;
        syn = qmul_ref(ny, factor) + tangy;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end else if (model_sel == 1) begin  // MODEL_FISHEYE (division model)
        r4 = qmul_ref(r2, r2);
        denom_raw = ONE_Q16 + qmul_ref(k1, r2) + qmul_ref(k2, r4);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(qmul_ref(ny, recip_denom), fy_pix);
      end else if (model_sel == 5) begin  // MODEL_PANORAMIC (division model, x only)
        denom_raw = ONE_Q16 + qmul_ref(k1, qmul_ref(nx, nx));
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(ny, fy_pix);
      end else if (model_sel == 3) begin  // MODEL_PERSPECTIVE (homography)
        xq = longint'(x) <<< FRAC_BITS;
        yq = longint'(y) <<< FRAC_BITS;
        denom_raw = ONE_Q16 + qmul_ref(h31, xq) + qmul_ref(h32, yq);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        num_x = qmul_ref(h11, xq) + qmul_ref(h12, yq) + h13;
        num_y = qmul_ref(h21, xq) + qmul_ref(h22, yq) + h23;
        sx = qmul_ref(num_x, recip_denom);
        sy = qmul_ref(num_y, recip_denom);
      end else begin  // MODEL_AFFINE / MODEL_SCALING: reserved hooks, identity
        sxn = nx;
        syn = ny;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end
    end
  endtask


  // ---- DUT ---------------------------------------------------------------
  logic clk = 0, rst_n = 0;
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

  localparam int COORD_GEN_LATENCY = 23;  // coord_gen.sv's documented pipeline depth

  always #5 clk = ~clk;

  int total_checks, total_fail;

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
      wait_cycles = 0;
      while (!out_valid && wait_cycles < 100) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end

      total_checks = total_checks + 1;
      if (!out_valid) begin
        $display("[%s] (%0d,%0d) FAIL: out_valid not asserted within timeout", label, x, y);
        total_fail = total_fail + 1;
      end else begin
        diff_x = longint'(out_sx_q16) - exp_sx; if (diff_x < 0) diff_x = -diff_x;
        diff_y = longint'(out_sy_q16) - exp_sy; if (diff_y < 0) diff_y = -diff_y;
        // small tolerance for reciprocal-divider rounding (this
        // testbench's recip_ref is an exact integer divide; the RTL uses
        // an iterative approximation elsewhere in the design -- coord_gen
        // itself just consumes a precomputed reciprocal, so this
        // tolerance covers only qmul truncation propagation, not the
        // reciprocal's own approximation)
        if (diff_x <= 4 && diff_y <= 4) begin
          $display("[%s] (%0d,%0d) PASS  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
        end else begin
          $display("[%s] (%0d,%0d) FAIL  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
          total_fail = total_fail + 1;
        end
      end
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
    cfg.cx_pix = 32'sd240 <<< 16; cfg.cy_pix = 32'sd360 <<< 16;
    cfg.fx_pix = 32'sd240 <<< 16; cfg.fy_pix = 32'sd360 <<< 16;
    cfg.recip_fx = recip_ref(cfg.fx_pix); cfg.recip_fy = recip_ref(cfg.fy_pix);

    cfg.model_sel = MODEL_RADIAL;
    cfg.k1 = -32'sd6554; cfg.k2 = 32'sd1311; cfg.k3 = 0; cfg.p1 = 32'sd819; cfg.p2 = -32'sd819;
    check_point("large_frame_radial",       0,   0);
    check_point("large_frame_radial",     479,   0);
    check_point("large_frame_radial",       0, 719);
    check_point("large_frame_radial",     479, 719);
    check_point("large_frame_radial",     240, 360);

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
    cfg.h31 = 32'sd26; cfg.h32 = -32'sd13;   // small keystone, same order as the full-scale test
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
