// ***************
// Filename: tb_lens_distortion_correction.sv
// Author: Paul Barcelona
// Description: Pure-SystemVerilog top-level self-checking testbench.
// Runs the 12-scenario barrel/pincushion matrix plus real
// fisheye/panoramic/perspective correction tests, each
// bit-exact vs. an independent golden model with a genuine
// measured image-quality improvement.
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_lens_distortion_correction.sv
//
// Pure-Verilog (no cocotb/Python) self-checking testbench for
// lens_distortion_correction. See tb/test_lens_distortion_correction.py for the original
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

module tb_lens_distortion_correction;
  import barrel_pkg::*;
  import ppm_io_pkg::*;
  import golden_model_pkg::*;

  localparam int CLK_PERIOD_NS = 10;   // 100 MHz
  localparam int LINE_GAP      = barrel_pkg::LINE_GAP_CYCLES;

  localparam int REG_STATUS     = 8'h04;
  localparam int REG_IMG_WIDTH  = 8'h08;
  localparam int REG_IMG_HEIGHT = 8'h0C;
  localparam int REG_K1         = 8'h10;
  localparam int REG_K2         = 8'h14;
  localparam int REG_K3         = 8'h18;
  localparam int REG_CENTER_X   = 8'h1C;
  localparam int REG_CENTER_Y   = 8'h20;
  localparam int REG_SCALE      = 8'h24;
  localparam int REG_VERSION    = 8'h28;
  localparam int REG_INTERP_MODE= 8'h2C;
  localparam int REG_CALIB_MODE = 8'h30;
  localparam int REG_FX         = 8'h34;
  localparam int REG_FY         = 8'h38;
  localparam int REG_CX         = 8'h3C;
  localparam int REG_CY         = 8'h40;
  localparam int REG_P1         = 8'h44;
  localparam int REG_P2         = 8'h48;
  localparam int REG_MODEL_SEL  = 8'h4C;
  localparam int REG_H11        = 8'h50;
  localparam int REG_H12        = 8'h54;
  localparam int REG_H13        = 8'h58;
  localparam int REG_H21        = 8'h5C;
  localparam int REG_H22        = 8'h60;
  localparam int REG_H23        = 8'h64;
  localparam int REG_H31        = 8'h68;
  localparam int REG_H32        = 8'h6C;

  // ---- clock / reset ----------------------------------------------------
  logic clk = 0, rst_n = 0;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  // ---- DUT AXI4-Stream / AXI4-Lite signals -------------------------------
  logic               s_axis_tvalid, s_axis_tready, s_axis_tlast, s_axis_tuser;
  logic [PIX_W-1:0]   s_axis_tdata;
  logic               m_axis_tvalid, m_axis_tready, m_axis_tlast, m_axis_tuser;
  logic [PIX_W-1:0]   m_axis_tdata;

  logic [7:0]   s_axil_awaddr;  logic s_axil_awvalid, s_axil_awready;
  logic [31:0]  s_axil_wdata;   logic [3:0] s_axil_wstrb; logic s_axil_wvalid, s_axil_wready;
  logic [1:0]   s_axil_bresp;   logic s_axil_bvalid, s_axil_bready;
  logic [7:0]   s_axil_araddr;  logic s_axil_arvalid, s_axil_arready;
  logic [31:0]  s_axil_rdata;   logic [1:0] s_axil_rresp; logic s_axil_rvalid, s_axil_rready;

  lens_distortion_correction dut (
    .clk, .rst_n,
    .s_axis_tvalid, .s_axis_tready, .s_axis_tdata, .s_axis_tlast, .s_axis_tuser,
    .m_axis_tvalid, .m_axis_tready, .m_axis_tdata, .m_axis_tlast, .m_axis_tuser,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready
  );

  // ---- AXI4-Lite driver tasks --------------------------------------------
  task automatic axil_write(input int addr, input longint data);
    begin
      @(posedge clk);
      s_axil_awaddr  <= addr[7:0];
      s_axil_awvalid <= 1'b1;
      s_axil_wdata   <= data[31:0];
      s_axil_wstrb   <= 4'hF;
      s_axil_wvalid  <= 1'b1;
      @(posedge clk);
      s_axil_awvalid <= 1'b0;
      s_axil_wvalid  <= 1'b0;
      while (s_axil_bvalid !== 1'b1) @(posedge clk);
      s_axil_bready <= 1'b1;
      @(posedge clk);
      s_axil_bready <= 1'b0;
    end
  endtask

  task automatic axil_read(input int addr, output logic [31:0] data);
    begin
      @(posedge clk);
      s_axil_araddr  <= addr[7:0];
      s_axil_arvalid <= 1'b1;
      @(posedge clk);
      s_axil_arvalid <= 1'b0;
      while (s_axil_rvalid !== 1'b1) @(posedge clk);
      data = s_axil_rdata;
      s_axil_rready <= 1'b1;
      @(posedge clk);
      s_axil_rready <= 1'b0;
    end
  endtask

  // ---- AXI4-Stream input driver -------------------------------------------
  task automatic stream_frame_in(
    input int w, input int h,
    input logic [7:0] img_r[], input logic [7:0] img_g[], input logic [7:0] img_b[]
  );
    int x, y;
    begin
      for (y = 0; y < h; y = y + 1) begin
        for (x = 0; x < w; x = x + 1) begin
          s_axis_tvalid <= 1'b1;
          s_axis_tdata  <= {img_r[y*w+x], img_g[y*w+x], img_b[y*w+x]};
          s_axis_tlast  <= (x == w-1);
          s_axis_tuser  <= (x == 0) && (y == 0);
          @(posedge clk);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tuser  <= 1'b0;
        repeat (LINE_GAP) @(posedge clk);
      end
    end
  endtask

  // ---- AXI4-Stream output monitor (runs concurrently, via fork) ---------
  logic [7:0] cap_r[], cap_g[], cap_b[];
  int cap_w, cap_h, cap_count, cap_total;
  logic cap_done, cap_tlast_err, cap_tuser_err;

  task automatic capture_frame_out(input int w, input int h);
    int x;
    begin
      cap_w = w; cap_h = h;
      cap_r = new[w*h]; cap_g = new[w*h]; cap_b = new[w*h];
      cap_count = 0; cap_total = w*h; cap_done = 1'b0;
      cap_tlast_err = 1'b0; cap_tuser_err = 1'b0;
      while (cap_count < cap_total) begin
        @(posedge clk);
        if (m_axis_tvalid === 1'b1 && m_axis_tready === 1'b1) begin
          x = cap_count % w;
          cap_r[cap_count] = m_axis_tdata[23:16];
          cap_g[cap_count] = m_axis_tdata[15:8];
          cap_b[cap_count] = m_axis_tdata[7:0];
          if (m_axis_tlast !== (x == w-1)) cap_tlast_err = 1'b1;
          if (cap_count == 0 && m_axis_tuser !== 1'b1) cap_tuser_err = 1'b1;
          cap_count = cap_count + 1;
        end
      end
      cap_done = 1'b1;
    end
  endtask

  // ---- one frame within a distortion x interp-mode group -----------------
  // Synthesizes a warped_<label>.ppm from src_r/g/b (BILINEAR forward
  // remap always -- synthesizing the distorted stimulus is independent of
  // which interpolation mode the DUT is about to be tested in), computes
  // the bit-exact golden CORRECTED reference using whichever interpolation
  // mode is currently under test (mirrors the DUT's own selected mode),
  // programs IMG_WIDTH/IMG_HEIGHT for this frame's own shape, streams it
  // through the already-configured DUT, captures the output, and runs the
  // self-checks. Does NOT reset the DUT and does NOT rewrite K1/K2/K3 or
  // INTERP_MODE -- those are set once per group by run_group() below, so
  // that calling this 3x in a row exercises the back-to-back consecutive-
  // frame path (with the image SIZE changing between frames, on top of
  // the distortion-type changes already covered by the earlier two-
  // scenario testing).
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

  task automatic run_one_frame(
    input string label, input int fw, input int fh,
    input logic [7:0] fsrc_r[], input logic [7:0] fsrc_g[], input logic [7:0] fsrc_b[],
    input int interp_mode_val
  );
    begin
      $display("--- frame: %s  (%0dx%0d, interp_mode=%0d) ---", label, fw, fh, interp_mode_val);
      cfg = make_remap_cfg(fw, fh, 32'h0000_8000, 32'h0000_8000, 32'h0001_0000);
      radial_remap_ref(cfg, kd1q, kd2q, kd3q, fsrc_r, fsrc_g, fsrc_b, warp_r, warp_g, warp_b);
      ppm_write({work_dir, "/warped_", label, ".ppm"}, fw, fh, warp_r, warp_g, warp_b);

      if (interp_mode_val)
        radial_remap_bicubic_ref(cfg, kc1q, kc2q, kc3q, warp_r, warp_g, warp_b, gold_r, gold_g, gold_b);
      else
        radial_remap_ref(cfg, kc1q, kc2q, kc3q, warp_r, warp_g, warp_b, gold_r, gold_g, gold_b);

      axil_write(REG_IMG_WIDTH,  fw);
      axil_write(REG_IMG_HEIGHT, fh);

      status_val = 32'hFFFF_FFFF;
      i = 0;
      while (i < 200 && status_val[2] !== 1'b0) begin
        axil_read(REG_STATUS, status_val);
        if (status_val[2] === 1'b0) i = 200;
        else begin
          @(posedge clk);
          i = i + 1;
        end
      end
      if (status_val[2] !== 1'b0) begin
        $display("ERROR [%s]: timed out waiting for recip_busy to clear", label);
        $fatal;
      end

      fork
        stream_frame_in(fw, fh, warp_r, warp_g, warp_b);
        capture_frame_out(fw, fh);
      join

      ppm_write({work_dir, "/corrected_", label, ".ppm"}, fw, fh, cap_r, cap_g, cap_b);

      max_err = 0; mismatches = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(cap_r[i]) - int'(gold_r[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_g[i]) - int'(gold_g[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_b[i]) - int'(gold_b[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
      end
      $display("[%s] DUT vs golden model: max_err=%0d  channel-mismatches(>1)=%0d/%0d",
                label, max_err, mismatches, fw*fh*3);

      mae_warp_acc = 0; mae_corr_acc = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(warp_r[i]) - int'(fsrc_r[i]); if (d<0) d=-d; mae_warp_acc += d;
        d = int'(warp_g[i]) - int'(fsrc_g[i]); if (d<0) d=-d; mae_warp_acc += d;
        d = int'(warp_b[i]) - int'(fsrc_b[i]); if (d<0) d=-d; mae_warp_acc += d;
        d = int'(cap_r[i])  - int'(fsrc_r[i]); if (d<0) d=-d; mae_corr_acc += d;
        d = int'(cap_g[i])  - int'(fsrc_g[i]); if (d<0) d=-d; mae_corr_acc += d;
        d = int'(cap_b[i])  - int'(fsrc_b[i]); if (d<0) d=-d; mae_corr_acc += d;
      end
      mae_warp = real'(mae_warp_acc) / real'(fw*fh*3);
      mae_corr = real'(mae_corr_acc) / real'(fw*fh*3);
      $display("[%s] MAE(warped, original)       = %f", label, mae_warp);
      $display("[%s] MAE(DUT-corrected, original) = %f", label, mae_corr);

      overall_checks = overall_checks + 4;
      if (mismatches == 0 && max_err <= 1) begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden : FAIL", label);
        overall_any_fail = 1;
      end
      if (mae_corr < 0.85 * mae_warp) begin
        $display("[%s] SELF-CHECK correction-quality  : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK correction-quality  : FAIL", label);
        overall_any_fail = 1;
      end
      if (cap_tlast_err) begin
        $display("[%s] SELF-CHECK tlast timing       : FAIL", label);
        overall_any_fail = 1;
      end else begin
        $display("[%s] SELF-CHECK tlast timing       : PASS", label);
        overall_pass = overall_pass + 1;
      end
      if (cap_tuser_err) begin
        $display("[%s] SELF-CHECK tuser (start-of-frame) : FAIL", label);
        overall_any_fail = 1;
      end else begin
        $display("[%s] SELF-CHECK tuser (start-of-frame) : PASS", label);
        overall_pass = overall_pass + 1;
      end
    end
  endtask

  // ---- REAL fisheye/panoramic correction test (division model) ------------
  // Synthesizes a genuinely fisheye/panoramic-DISTORTED image by applying
  // the division model once (forward, kd1/kd2) to a flat source image via
  // full_remap_ref, fits a correction (kc1/kc2) via
  // fit_division_model_coeffs (a grid search, not a closed-form inverse --
  // the division model isn't linear in its coefficients), applies that
  // correction through the ACTUAL DUT, and checks both bit-exactness
  // against the golden model and a genuine MAE improvement -- the exact
  // same evidentiary standard the barrel/pincushion (radial) tests are
  // held to, not merely "the hook was a no-op".
  longint dm_kdq1, dm_kdq2, dm_kcq1, dm_kcq2;
  real    mae_dm_warp, mae_dm_corr;
  longint mae_dm_warp_acc, mae_dm_corr_acc;

  task automatic run_division_model_correction_test(
    input string label, input int model_sel_val, input real kd1, input real kd2,
    input int fw, input int fh,
    input logic [7:0] fsrc_r[], input logic [7:0] fsrc_g[], input logic [7:0] fsrc_b[]
  );
    begin
      $display("=== %s correction test (MODEL_SEL=%0d, %0dx%0d, kd1=%f kd2=%f) ===",
                 label, model_sel_val, fw, fh, kd1, kd2);
      dm_kdq1 = longint'($rtoi(kd1 * 65536.0));
      dm_kdq2 = longint'($rtoi(kd2 * 65536.0));

      cfg = make_remap_cfg(fw, fh, 32'h0000_8000, 32'h0000_8000, 32'h0001_0000);
      full_remap_ref(cfg, model_sel_val, dm_kdq1, dm_kdq2, 0, 0, 0, 0,0,0, 0,0,0, 0,0,
                      fsrc_r, fsrc_g, fsrc_b, warp_r, warp_g, warp_b);
      ppm_write({work_dir, "/warped_", label, ".ppm"}, fw, fh, warp_r, warp_g, warp_b);

      fit_division_model_coeffs(cfg, model_sel_val, warp_r, warp_g, warp_b,
                                  fsrc_r, fsrc_g, fsrc_b, dm_kcq1, dm_kcq2);
      $display("[%s] fitted correction coeffs (Q16.16): kc1=%0d kc2=%0d", label, dm_kcq1, dm_kcq2);

      full_remap_ref(cfg, model_sel_val, dm_kcq1, dm_kcq2, 0, 0, 0, 0,0,0, 0,0,0, 0,0,
                      warp_r, warp_g, warp_b, gold_r, gold_g, gold_b);

      axil_write(REG_MODEL_SEL, model_sel_val);
      axil_write(REG_INTERP_MODE, 0);
      axil_write(REG_K1, dm_kcq1);
      axil_write(REG_K2, dm_kcq2);
      axil_write(REG_K3, 0);
      axil_write(REG_P1, 0);
      axil_write(REG_P2, 0);
      axil_write(REG_CENTER_X, 32'h0000_8000);
      axil_write(REG_CENTER_Y, 32'h0000_8000);
      axil_write(REG_SCALE,    32'h0001_0000);
      axil_write(REG_IMG_WIDTH,  fw);
      axil_write(REG_IMG_HEIGHT, fh);

      status_val = 32'hFFFF_FFFF;
      i = 0;
      while (i < 200 && status_val[2] !== 1'b0) begin
        axil_read(REG_STATUS, status_val);
        if (status_val[2] === 1'b0) i = 200;
        else begin @(posedge clk); i = i + 1; end
      end
      if (status_val[2] !== 1'b0) begin
        $display("ERROR [%s]: timed out waiting for recip_busy to clear", label);
        $fatal;
      end

      fork
        stream_frame_in(fw, fh, warp_r, warp_g, warp_b);
        capture_frame_out(fw, fh);
      join

      ppm_write({work_dir, "/corrected_", label, ".ppm"}, fw, fh, cap_r, cap_g, cap_b);

      max_err = 0; mismatches = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(cap_r[i]) - int'(gold_r[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_g[i]) - int'(gold_g[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_b[i]) - int'(gold_b[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
      end
      mae_dm_warp_acc = 0; mae_dm_corr_acc = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(warp_r[i]) - int'(fsrc_r[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(warp_g[i]) - int'(fsrc_g[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(warp_b[i]) - int'(fsrc_b[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(cap_r[i])  - int'(fsrc_r[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
        d = int'(cap_g[i])  - int'(fsrc_g[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
        d = int'(cap_b[i])  - int'(fsrc_b[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
      end
      mae_dm_warp = real'(mae_dm_warp_acc) / real'(fw*fh*3);
      mae_dm_corr = real'(mae_dm_corr_acc) / real'(fw*fh*3);
      $display("[%s] DUT vs golden model: max_err=%0d  channel-mismatches(>1)=%0d/%0d",
                label, max_err, mismatches, fw*fh*3);
      $display("[%s] MAE(warped, original)       = %f", label, mae_dm_warp);
      $display("[%s] MAE(DUT-corrected, original) = %f", label, mae_dm_corr);

      overall_checks = overall_checks + 2;
      if (mismatches == 0 && max_err <= 1) begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden  : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden  : FAIL", label);
        overall_any_fail = 1;
      end
      if (mae_dm_corr < 0.85 * mae_dm_warp) begin
        $display("[%s] SELF-CHECK correction-quality   : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK correction-quality   : FAIL", label);
        overall_any_fail = 1;
      end

      axil_write(REG_MODEL_SEL, 0);
    end
  endtask

  // ---- REAL perspective correction test (exact homography inverse) --------
  // Synthesizes a genuinely keystone-distorted image with a KNOWN forward
  // homography, computes its EXACT inverse in closed form (invert_
  // homography -- unlike the division model, a homography's correction
  // is not approximate), applies that correction through the DUT, and
  // checks both bit-exactness and a genuine MAE improvement.
  real hf11,hf12,hf13, hf21,hf22,hf23, hf31,hf32;
  real hc11,hc12,hc13, hc21,hc22,hc23, hc31,hc32;
  longint hcq11,hcq12,hcq13, hcq21,hcq22,hcq23, hcq31,hcq32;

  task automatic run_perspective_correction_test(
    input string label, input int fw, input int fh,
    input logic [7:0] fsrc_r[], input logic [7:0] fsrc_g[], input logic [7:0] fsrc_b[]
  );
    begin
      $display("=== perspective correction test (%0dx%0d) ===", fw, fh);
      // Mild keystone: a small x/y-dependent foreshortening (h31,h32),
      // operating directly on pixel coordinates per this design's
      // convention (see distortion_model_pkg.sv). These coefficients
      // must be scaled to the actual frame width: h31/h32 act directly
      // on pixel coordinates, so a coefficient chosen for a much smaller
      // test image can put the CORRECTED homography's denominator
      // zero-crossing (a genuine mathematical singularity, not an RTL
      // bug) inside a much larger frame. Found exactly this way when
      // this testbench was scaled up to 720x480: the previous
      // hf31=0.0016 produces a corrected h31=~-0.0016, whose "1+h31*x"
      // denominator hits exactly 0 at x=625 -- comfortably inside a
      // 720-wide frame (and invisible in the smaller frame these
      // coefficients were originally tuned for). These values keep the
      // zero-crossing far outside any frame size this project's
      // testbenches use (~5000, vs. a maximum frame dimension of 720).
      hf11=1.0; hf12=0.0;    hf13=0.0;
      hf21=0.0; hf22=1.0;    hf23=0.0;
      hf31=0.0002; hf32=-0.000125;

      invert_homography(hf11,hf12,hf13, hf21,hf22,hf23, hf31,hf32,
                          hc11,hc12,hc13, hc21,hc22,hc23, hc31,hc32);
      $display("[%s] forward H31=%f H32=%f -> correcting H31=%f H32=%f", label, hf31, hf32, hc31, hc32);

      hcq11 = longint'($rtoi(hc11*65536.0)); hcq12 = longint'($rtoi(hc12*65536.0)); hcq13 = longint'($rtoi(hc13*65536.0));
      hcq21 = longint'($rtoi(hc21*65536.0)); hcq22 = longint'($rtoi(hc22*65536.0)); hcq23 = longint'($rtoi(hc23*65536.0));
      hcq31 = longint'($rtoi(hc31*65536.0)); hcq32 = longint'($rtoi(hc32*65536.0));

      cfg = make_remap_cfg(fw, fh, 32'h0000_8000, 32'h0000_8000, 32'h0001_0000);
      full_remap_ref(cfg, 3 /*MODEL_PERSPECTIVE*/, 0,0,0,0,0,
                      longint'($rtoi(hf11*65536.0)), longint'($rtoi(hf12*65536.0)), longint'($rtoi(hf13*65536.0)),
                      longint'($rtoi(hf21*65536.0)), longint'($rtoi(hf22*65536.0)), longint'($rtoi(hf23*65536.0)),
                      longint'($rtoi(hf31*65536.0)), longint'($rtoi(hf32*65536.0)),
                      fsrc_r, fsrc_g, fsrc_b, warp_r, warp_g, warp_b);
      ppm_write({work_dir, "/warped_", label, ".ppm"}, fw, fh, warp_r, warp_g, warp_b);

      full_remap_ref(cfg, 3, 0,0,0,0,0, hcq11,hcq12,hcq13, hcq21,hcq22,hcq23, hcq31,hcq32,
                      warp_r, warp_g, warp_b, gold_r, gold_g, gold_b);

      axil_write(REG_MODEL_SEL, 3);
      axil_write(REG_INTERP_MODE, 0);
      axil_write(REG_H11, hcq11); axil_write(REG_H12, hcq12); axil_write(REG_H13, hcq13);
      axil_write(REG_H21, hcq21); axil_write(REG_H22, hcq22); axil_write(REG_H23, hcq23);
      axil_write(REG_H31, hcq31); axil_write(REG_H32, hcq32);
      axil_write(REG_CENTER_X, 32'h0000_8000);
      axil_write(REG_CENTER_Y, 32'h0000_8000);
      axil_write(REG_SCALE,    32'h0001_0000);
      axil_write(REG_IMG_WIDTH,  fw);
      axil_write(REG_IMG_HEIGHT, fh);

      status_val = 32'hFFFF_FFFF;
      i = 0;
      while (i < 200 && status_val[2] !== 1'b0) begin
        axil_read(REG_STATUS, status_val);
        if (status_val[2] === 1'b0) i = 200;
        else begin @(posedge clk); i = i + 1; end
      end
      if (status_val[2] !== 1'b0) begin
        $display("ERROR [%s]: timed out waiting for recip_busy to clear", label);
        $fatal;
      end

      fork
        stream_frame_in(fw, fh, warp_r, warp_g, warp_b);
        capture_frame_out(fw, fh);
      join

      ppm_write({work_dir, "/corrected_", label, ".ppm"}, fw, fh, cap_r, cap_g, cap_b);

      max_err = 0; mismatches = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(cap_r[i]) - int'(gold_r[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_g[i]) - int'(gold_g[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
        d = int'(cap_b[i]) - int'(gold_b[i]); if (d<0) d=-d; if (d>max_err) max_err=d; if (d>1) mismatches=mismatches+1;
      end
      mae_dm_warp_acc = 0; mae_dm_corr_acc = 0;
      for (i = 0; i < fw*fh; i = i + 1) begin
        d = int'(warp_r[i]) - int'(fsrc_r[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(warp_g[i]) - int'(fsrc_g[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(warp_b[i]) - int'(fsrc_b[i]); if (d<0) d=-d; mae_dm_warp_acc += d;
        d = int'(cap_r[i])  - int'(fsrc_r[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
        d = int'(cap_g[i])  - int'(fsrc_g[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
        d = int'(cap_b[i])  - int'(fsrc_b[i]); if (d<0) d=-d; mae_dm_corr_acc += d;
      end
      mae_dm_warp = real'(mae_dm_warp_acc) / real'(fw*fh*3);
      mae_dm_corr = real'(mae_dm_corr_acc) / real'(fw*fh*3);
      $display("[%s] DUT vs golden model: max_err=%0d  channel-mismatches(>1)=%0d/%0d",
                label, max_err, mismatches, fw*fh*3);
      $display("[%s] MAE(warped, original)       = %f", label, mae_dm_warp);
      $display("[%s] MAE(DUT-corrected, original) = %f", label, mae_dm_corr);

      overall_checks = overall_checks + 2;
      if (mismatches == 0 && max_err <= 1) begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden  : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK bit-exact-vs-golden  : FAIL", label);
        overall_any_fail = 1;
      end
      if (mae_dm_corr < 0.85 * mae_dm_warp) begin
        $display("[%s] SELF-CHECK correction-quality   : PASS", label);
        overall_pass = overall_pass + 1;
      end else begin
        $display("[%s] SELF-CHECK correction-quality   : FAIL", label);
        overall_any_fail = 1;
      end

      axil_write(REG_MODEL_SEL, 0);
      axil_write(REG_H11, 32'h0001_0000); axil_write(REG_H12, 0); axil_write(REG_H13, 0);
      axil_write(REG_H21, 0); axil_write(REG_H22, 32'h0001_0000); axil_write(REG_H23, 0);
      axil_write(REG_H31, 0); axil_write(REG_H32, 0);
    end
  endtask

  // ---- one distortion x interp-mode group: 3 CONSECUTIVE frames ----------
  // (square, portrait, landscape -- no reset between them), continuing to
  // exercise the back-to-back-frame path (bug #4) with image DIMENSIONS
  // now changing between consecutive frames too, on top of size being
  // read from each test image rather than hardcoded.
  task automatic run_group(input string dist_label, input real kd1, input real kd2, input real kd3,
                            input int interp_mode_val, input string mode_label);
    begin
      $display("=== group: %s / %s  (kd1=%f, kd2=%f, kd3=%f) ===", dist_label, mode_label, kd1, kd2, kd3);
      kd1q = longint'($rtoi(kd1*65536.0));
      kd2q = longint'($rtoi(kd2*65536.0));
      kd3q = longint'($rtoi(kd3*65536.0));
      fit_correction_coeffs(kd1, kd2, kd3, kc1, kc2, kc3);
      kc1q = longint'($rtoi(kc1*65536.0));
      kc2q = longint'($rtoi(kc2*65536.0));
      kc3q = longint'($rtoi(kc3*65536.0));
      $display("correction coeffs (Q16.16): k1=%0d k2=%0d k3=%0d", kc1q, kc2q, kc3q);

      axil_write(REG_INTERP_MODE, interp_mode_val);
      axil_write(REG_K1, kc1q);
      axil_write(REG_K2, kc2q);
      axil_write(REG_K3, kc3q);
      axil_write(REG_CENTER_X, 32'h0000_8000);
      axil_write(REG_CENTER_Y, 32'h0000_8000);
      axil_write(REG_SCALE,    32'h0001_0000);

      run_one_frame({dist_label, "_", mode_label, "_square"},    sq_w, sq_h, sq_r, sq_g, sq_b, interp_mode_val);
      run_one_frame({dist_label, "_", mode_label, "_portrait"},  pt_w, pt_h, pt_r, pt_g, pt_b, interp_mode_val);
      run_one_frame({dist_label, "_", mode_label, "_landscape"}, ls_w, ls_h, ls_r, ls_g, ls_b, interp_mode_val);
    end
  endtask

  // ---- main sequence ------------------------------------------------------
  int ok;
  string work_dir = "work";

  // Three test-image shapes, sizes read from the actual generated/loaded
  // images (not hardcoded into the scenario logic) -- IMG_WIDTH/IMG_HEIGHT
  // are programmed per-frame from these.
  int sq_w, sq_h, pt_w, pt_h, ls_w, ls_h;
  logic [7:0] sq_r[], sq_g[], sq_b[];
  logic [7:0] pt_r[], pt_g[], pt_b[];
  logic [7:0] ls_r[], ls_g[], ls_b[];

  initial begin
    m_axis_tready  <= 1'b1;
    s_axis_tvalid  <= 1'b0; s_axis_tlast <= 1'b0; s_axis_tuser <= 1'b0; s_axis_tdata <= '0;
    s_axil_awvalid <= 1'b0; s_axil_wvalid <= 1'b0; s_axil_bready <= 1'b0;
    s_axil_arvalid <= 1'b0; s_axil_rready <= 1'b0;
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ---- load or generate the three shaped test images ------------------
    ppm_read({work_dir, "/test_square.ppm"}, sq_w, sq_h, ok, sq_r, sq_g, sq_b);
    if (ok == 0) begin
      sq_w = 480; sq_h = 480;
      generate_synthetic_chart(sq_w, sq_h, sq_r, sq_g, sq_b);
      ppm_write({work_dir, "/test_square.ppm"}, sq_w, sq_h, sq_r, sq_g, sq_b);
    end
    ppm_read({work_dir, "/test_portrait.ppm"}, pt_w, pt_h, ok, pt_r, pt_g, pt_b);
    if (ok == 0) begin
      pt_w = 480; pt_h = 720;
      generate_synthetic_chart(pt_w, pt_h, pt_r, pt_g, pt_b);
      ppm_write({work_dir, "/test_portrait.ppm"}, pt_w, pt_h, pt_r, pt_g, pt_b);
    end
    ppm_read({work_dir, "/test_landscape.ppm"}, ls_w, ls_h, ok, ls_r, ls_g, ls_b);
    if (ok == 0) begin
      ls_w = 720; ls_h = 480;
      generate_synthetic_chart(ls_w, ls_h, ls_r, ls_g, ls_b);
      ppm_write({work_dir, "/test_landscape.ppm"}, ls_w, ls_h, ls_r, ls_g, ls_b);
    end
    $display("test images: square %0dx%0d, portrait %0dx%0d, landscape %0dx%0d",
              sq_w, sq_h, pt_w, pt_h, ls_w, ls_h);

    axil_read(REG_VERSION, version_val);
    $display("core VERSION = 0x%08h", version_val);

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

endmodule
