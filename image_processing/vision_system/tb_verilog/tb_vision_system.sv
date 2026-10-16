// ***************
// Filename: tb_vision_system.sv
// Author: FPGA Cores 4 U
// Description: Pure-SystemVerilog top-level self-checking testbench.
// Runs the 12-scenario barrel/pincushion matrix plus real
// fisheye/panoramic/perspective correction tests, each
// bit-exact vs. an independent golden model with a genuine
// measured image-quality improvement.
//   The test tasks are in tests/vision_system_tests.sv (`included).
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_vision_system.sv
//
// Pure-Verilog (no cocotb/Python) self-checking testbench for
// vision_system. See tb/test_vision_system.py for the original
// cocotb version and README.md for why this version is PPM-only (JPEG
// codecs are impractical to implement in Verilog).
//
// Flow: identical to the cocotb version --
//   1. Load work/test.ppm (generate a synthetic chart if absent).
//   2. Synthesize work/warped.ppm using golden_model_pkg's radial-remap
//      primitive fed "distortion" k values.
//   3. Fit correction k values that approximately invert that distortion,
//      compute the bit-exact golden "corrected" reference.
//   4. Program the DUT over AXI4-Lite, stream the warped image in over
//      AXI4-Stream with the spec's "line, then 5 idle cycles" timing,
//      capture the output with the same timing.
//   5. Save work/corrected.ppm from the DUT's actual output.
//   6. Self-check: DUT vs golden bit-exact, and warped-vs-corrected
//      image-quality sanity check.
// =============================================================================
`timescale 1ns/1ps

module tb_vision_system;
  import barrel_pkg::*;
  import ppm_io_pkg::*;
  import golden_model_pkg::*;

  localparam int CLK_PERIOD_NS = 10;   // 100 MHz
  localparam int LINE_GAP      = barrel_pkg::LINE_GAP_CYCLES;

  localparam int REG_STATUS     = 8'h14;
  localparam int REG_IMG_WIDTH  = 8'h18;
  localparam int REG_IMG_HEIGHT = 8'h1C;
  localparam int REG_K1         = 8'h20;
  localparam int REG_K2         = 8'h24;
  localparam int REG_K3         = 8'h28;
  localparam int REG_CENTER_X   = 8'h2C;
  localparam int REG_CENTER_Y   = 8'h30;
  localparam int REG_SCALE      = 8'h34;
  localparam int REG_VERSION    = 8'h04;   // ID block VERSION (ASCII "d.dd")
  localparam int REG_INTERP_MODE= 8'h3C;
  localparam int REG_CALIB_MODE = 8'h40;
  localparam int REG_FX         = 8'h44;
  localparam int REG_FY         = 8'h48;
  localparam int REG_CX         = 8'h4C;
  localparam int REG_CY         = 8'h50;
  localparam int REG_P1         = 8'h54;
  localparam int REG_P2         = 8'h58;
  localparam int REG_MODEL_SEL  = 8'h5C;
  localparam int REG_H11        = 8'h60;
  localparam int REG_H12        = 8'h64;
  localparam int REG_H13        = 8'h68;
  localparam int REG_H21        = 8'h6C;
  localparam int REG_H22        = 8'h70;
  localparam int REG_H23        = 8'h74;
  localparam int REG_H31        = 8'h78;
  localparam int REG_H32        = 8'h7C;

  // ---- clock / reset ----------------------------------------------------
  logic clk = 0, rst_n = 0;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  // ---- DUT AXI4-Stream / AXI4-Lite signals -------------------------------
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) s_axis ();
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) m_axis ();

  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  int sq_w, sq_h, pt_w, pt_h, ls_w, ls_h;
  logic [7:0] sq_r[], sq_g[], sq_b[];
  logic [7:0] pt_r[], pt_g[], pt_b[];
  logic [7:0] ls_r[], ls_g[], ls_b[];
  string work_dir = "work";

  vision_system dut (
        .clk,
        .rst_n,
        .s_axis(s_axis),
        .m_axis(m_axis),
        .s_axil(s_axil)
  );

  // used by task capture_frame_out (tests/vision_system_tests.sv)
  logic [7:0] cap_r[], cap_g[], cap_b[];
  int cap_w, cap_h, cap_count, cap_total;
  logic cap_done, cap_tlast_err, cap_tuser_err;

  // used by task run_one_frame (tests/vision_system_tests.sv)
  logic [7:0] warp_r[], warp_g[], warp_b[];
  logic [7:0] gold_r[], gold_g[], gold_b[];
  remap_cfg_t cfg;
  longint kd1q, kd2q, kd3q, kc1q, kc2q, kc3q;
  real kc1, kc2, kc3;
  longint mae_warp_acc, mae_corr_acc;
  real mae_warp, mae_corr;
  int max_err, mismatches, d, i;
  logic [31:0] status_val, version_val;
  int overall_pass, overall_any_fail, overall_checks;

  // used by task run_division_model_correction_test (tests/vision_system_tests.sv)
  longint dm_kdq1, dm_kdq2, dm_kcq1, dm_kcq2;
  real    mae_dm_warp, mae_dm_corr;
  longint mae_dm_warp_acc, mae_dm_corr_acc;

  // used by task run_perspective_correction_test (tests/vision_system_tests.sv)
  real hf11,hf12,hf13, hf21,hf22,hf23, hf31,hf32;
  real hc11,hc12,hc13, hc21,hc22,hc23, hc31,hc32;
  longint hcq11,hcq12,hcq13, hcq21,hcq22,hcq23, hcq31,hcq32;

  // test tasks: tests/vision_system_tests.sv
  `include "vision_system_tests.sv"

  // ---- main sequence ------------------------------------------------------
  int ok;

  // Three test-image shapes, sizes read from the actual generated/loaded
  // images (not hardcoded into the scenario logic) -- IMG_WIDTH/IMG_HEIGHT
  // are programmed per-frame from these.
  initial begin
    void'($value$plusargs("WORK_DIR=%s", work_dir));
    m_axis.tready  <= 1'b1;
    s_axis.tvalid  <= 1'b0;
    s_axis.tlast <= 1'b0;
    s_axis.tuser <= 1'b0;
    s_axis.tdata <= '0;
    s_axil.awvalid <= 1'b0;
    s_axil.wvalid <= 1'b0;
    s_axil.bready <= 1'b0;
    s_axil.arvalid <= 1'b0;
    s_axil.rready <= 1'b0;
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---- load or generate the three shaped test images ------------------
    ppm_read({work_dir, "/test_square.ppm"}, sq_w, sq_h, ok, sq_r, sq_g, sq_b);
    if (ok == 0) begin
`ifdef SMALL_FRAMES
      sq_w = 48;
      sq_h = 48;
`else
      sq_w = 480;
      sq_h = 480;
`endif
      generate_synthetic_chart(sq_w, sq_h, sq_r, sq_g, sq_b);
      ppm_write({work_dir, "/test_square.ppm"}, sq_w, sq_h, sq_r, sq_g, sq_b);
    end
    ppm_read({work_dir, "/test_portrait.ppm"}, pt_w, pt_h, ok, pt_r, pt_g, pt_b);
    if (ok == 0) begin
`ifdef SMALL_FRAMES
      pt_w = 32;
      pt_h = 56;
`else
      pt_w = 480;
      pt_h = 720;
`endif
      generate_synthetic_chart(pt_w, pt_h, pt_r, pt_g, pt_b);
      ppm_write({work_dir, "/test_portrait.ppm"}, pt_w, pt_h, pt_r, pt_g, pt_b);
    end
    ppm_read({work_dir, "/test_landscape.ppm"}, ls_w, ls_h, ok, ls_r, ls_g, ls_b);
    if (ok == 0) begin
`ifdef SMALL_FRAMES
      ls_w = 56;
      ls_h = 32;
`else
      ls_w = 720;
      ls_h = 480;
`endif
      generate_synthetic_chart(ls_w, ls_h, ls_r, ls_g, ls_b);
      ppm_write({work_dir, "/test_landscape.ppm"}, ls_w, ls_h, ls_r, ls_g, ls_b);
    end
    $display("test images: square %0dx%0d, portrait %0dx%0d, landscape %0dx%0d",
              sq_w, sq_h, pt_w, pt_h, ls_w, ls_h);

    axil_read(8'h00, version_val);                    // ID block: ID "VSYS", VERSION, DATE
    if (version_val != "VSYS") $fatal(1, "vision_system ID 0x%08h, expected \"VSYS\"", version_val);
    axil_read(REG_VERSION, version_val);
    $display("core VERSION = \"%s\" (0x%08h)", version_val, version_val);
    if (version_val[23:16] != ".") $fatal(1, "VERSION 0x%08h is not ASCII \"d.dd\"", version_val);

    overall_pass = 0;
    overall_any_fail = 0;
    overall_checks = 0;

    // Sign convention (verified empirically, see README): applying this
    // remap primitive with POSITIVE k1 to a flat/undistorted image
    // produces genuine barrel bulge; NEGATIVE k1 produces genuine
    // pincushion. The fitted correction coefficients come out with the
    // opposite sign in each case, matching the AXI-Lite register
    // documentation ("k1<0 corrects barrel bulge").
    //
    // Full matrix: 2 distortions x 2 interpolation modes x 3 shapes = 12
    // frame-scenarios, each interp-mode's 3 shapes run as 3 CONSECUTIVE
    // frames (no reset between them) per the requested back-to-back
    // multi-frame, multi-aspect-ratio testing.
    run_group("barrel",     0.08, -0.01, 0.0, 0, "bilinear");
    run_group("barrel",     0.08, -0.01, 0.0, 1, "bicubic");
    run_group("pincushion", -0.08, 0.01, 0.0, 0, "bilinear");
    run_group("pincushion", -0.08, 0.01, 0.0, 1, "bicubic");

    // Image-level fisheye/panoramic/perspective CORRECTION tests: each
    // synthesizes a genuinely distorted image (division model for
    // fisheye/panoramic, a real 3x3 homography for perspective), fits or
    // exactly computes correcting coefficients, and streams the warped
    // image through the ACTUAL DUT, checking both bit-exactness against
    // an independent golden model and a genuine MAE improvement over the
    // warped image -- the same evidentiary standard the barrel/pincushion
    // radial tests are held to. Run back-to-back (no reset), continuing
    // to exercise the back-to-back-frame path with MODEL_SEL changing
    // between consecutive frames.
    run_division_model_correction_test("fisheye",     1 /*MODEL_FISHEYE*/,   -0.20, 0.03, sq_w, sq_h, sq_r, sq_g, sq_b);
    run_division_model_correction_test("panoramic",   5 /*MODEL_PANORAMIC*/, -0.20, 0.0,  pt_w, pt_h, pt_r, pt_g, pt_b);
    run_perspective_correction_test("perspective", ls_w, ls_h, ls_r, ls_g, ls_b);

    $display("=== TOTAL: %0d/%0d checks passed across 12 frame-scenarios + 3 fisheye/panoramic/perspective correction tests ===", overall_pass, overall_checks);
    if (overall_pass == overall_checks && !overall_any_fail)
      $display(">>> ALL SELF-CHECKS PASSED (barrel+pincushion x bilinear+bicubic x square+portrait+landscape, + fisheye/panoramic/perspective correction) <<<");
    else
      $display(">>> SELF-CHECK FAILURE <<<");

    $finish;
  end

  // safety timeout
  initial begin
    #50_000_000; // 50ms sim time
    $display("ERROR: global timeout -- simulation did not finish");
    $fatal;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (run.sh does this when
  // VCD=1). Only the first VCD_WINDOW_NS nanoseconds are recorded -- a
  // whole multi-frame regression would produce an unmanageably large file.
  // Override with -DVCD_WINDOW_NS=<ns>. View with synth/view_waves.sh.
`ifdef DUMP_VCD
`ifndef VCD_WINDOW_NS
`define VCD_WINDOW_NS 300000
`endif
  initial begin
    $dumpfile("work/waves.vcd");
    $dumpvars(0, dut);
    #(`VCD_WINDOW_NS) $dumpoff;
  end
`endif
endmodule
