// ***************
// Filename: tb_scaler_mip.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for scaler_mip.
//   Runs the standard suite from scaler_tb_lib (identity, non-integer
//   up/down, mixed, 2x, 1x1 in/out, max size, junk before SOF, random
//   tvalid/tready stalls, full rate) and compares every output pixel
//   bit-exactly with an independent reference model (golden_pixel).
//   Plusargs: +IMG=<file.ppm> scale a PPM P6 image, +OUT_W/+OUT_H output
//   size, +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Inputs/outputs are written as PPM P6 images. Compile with
//   -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
//   Engine used directly with LEVELS = 3, ANISO_MAX_LOG2 = 2. The
//   reference builds its own mip pyramid; LOD/probe registers are derived
//   as in tools/scaler_coefs.py.
// Date: 2026-09-26

`timescale 1ns/1ps

// Maximum image size (frame buffer of the DUT and testbench arrays).
// Override at compile time for larger +IMG files, e.g. -DTB_MAX_W=640.
// Frame-store mode of the DUT (compile-time): -DTB_PINGPONG=1 double buffer,
// -DTB_LINE_BUF=1 line buffer (not for the mip-based IPs).
`ifndef TB_PINGPONG
`define TB_PINGPONG 0
`endif
`ifndef TB_LINE_BUF
`define TB_LINE_BUF 0
`endif
`ifndef TB_MAX_W
`define TB_MAX_W 48
`endif
`ifndef TB_MAX_H
`define TB_MAX_H 40
`endif
module tb_scaler_mip;
  // DUT configuration (also used by the reference model)
  localparam int CHANNELS   = 3;
  localparam int COMP_W     = 8;
  localparam int PIX_W      = CHANNELS * COMP_W;
  localparam int MAX_W      = `TB_MAX_W;
  localparam int MAX_H      = `TB_MAX_H;
  localparam int ADDR_W     = 14;
  localparam int LEVELS     = 3;
  localparam int ANISO_MAX  = 2;
  localparam int PHASE_BITS = 8;

  // clock, reset, AXI-Lite BFM, stream driver/checker, PPM I/O, test
  // sequencing (declares the signals connected to the DUT below)
  `include "scaler_tb_lib.svh"

  // Device under test (engine instantiated directly)
  scaler_mip #(.PINGPONG(`TB_PINGPONG), .ANISO_MAX_LOG2(ANISO_MAX), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                     .ADDR_W(ADDR_W), .LEVELS(LEVELS), .PHASE_BITS(PHASE_BITS)) dut (
    .clk, .rst_n,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
    .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast)
  );

  // ---------------------------------------------------------------- reference pyramid
  logic [PIX_W-1:0] mip [LEVELS][MAX_H][MAX_W];   // model pyramid
  int lw [LEVELS], lh [LEVELS];                    // level sizes

  // register values used for the current test
  int                 lod_reg, alog2;
  logic signed [31:0] pstep_x, pstep_y, pstart_x, pstart_y;
  int                 lod_override = -1;   // >= 0 forces LOD register

  // Build the reference pyramid from img[][] with the 2x2 box filter
  task automatic build_pyramid();
    lw[0] = in_w; lh[0] = in_h;
    for (int y = 0; y < in_h; y++) for (int x = 0; x < in_w; x++) mip[0][y][x] = img[y][x];
    for (int k = 1; k < LEVELS; k++) begin
      lw[k] = (lw[k-1] > 1) ? lw[k-1] / 2 : 1;
      lh[k] = (lh[k-1] > 1) ? lh[k-1] / 2 : 1;
      for (int y = 0; y < lh[k]; y++)
        for (int x = 0; x < lw[k]; x++)
          for (int c = 0; c < CHANNELS; c++) begin
            int s = 2;
            for (int j = 0; j < 2; j++)
              for (int i = 0; i < 2; i++)
                s += comp(mip[k-1][clampi(2*y+j, 0, lh[k-1]-1)][clampi(2*x+i, 0, lw[k-1]-1)], c);
            mip[k][y][x][c*COMP_W +: COMP_W] = COMP_W'(s >> 2);
          end
    end
  endtask

  // Component c of level k at (x, y), clamp-to-edge
  function automatic int lcomp(int k, int x, int y, int c);
    return comp(mip[k][clampi(y, 0, lh[k]-1)][clampi(x, 0, lw[k]-1)], c);
  endfunction

  // bilinear sample of level k at level-0 coordinate (u, v) in 16.16
  function automatic int bil(int k, longint u, longint v, int c);
    longint one = 1 << PHASE_BITS;
    longint rnd = 1 << (16 - PHASE_BITS - 1);
    longint uk = ((u + 32768) >>> k) - 32768 + rnd;
    longint vk = ((v + 32768) >>> k) - 32768 + rnd;
    int ix = int'(uk >>> 16), iy = int'(vk >>> 16);
    longint fx = (uk & 64'hFFFF) >> (16 - PHASE_BITS);
    longint fy = (vk & 64'hFFFF) >> (16 - PHASE_BITS);
    longint top = lcomp(k, ix, iy, c) * (one - fx) + lcomp(k, ix + 1, iy, c) * fx;
    longint bot = lcomp(k, ix, iy + 1, c) * (one - fx) + lcomp(k, ix + 1, iy + 1, c) * fx;
    return int'((top * (one - fy) + bot * fy + one * one / 2) >> (2 * PHASE_BITS));
  endfunction

  // Trilinear blend of levels la/lb for each probe, then rounded mean
  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    int la = lod_reg >> 8, f = lod_reg & 255, lb;
    int np = 1 << alog2;
    logic [PIX_W-1:0] r;
    if (la >= LEVELS - 1) begin la = LEVELS - 1; f = 0; end
    lb = (la + 1 > LEVELS - 1) ? LEVELS - 1 : la + 1;
    for (int c = 0; c < CHANNELS; c++) begin
      int sum = 0;
      for (int n = 0; n < np; n++) begin
        longint u = src_x(ox) + longint'(pstart_x) + n * longint'(pstep_x);
        longint v = src_y(oy) + longint'(pstart_y) + n * longint'(pstep_y);
        sum += (bil(la, u, v, c) * (256 - f) + bil(lb, u, v, c) * f + 128) >> 8;
      end
      r[c*COMP_W +: COMP_W] = COMP_W'((sum + np / 2) >> alog2);
    end
    return r;
  endfunction

  // ---------------------------------------------------------------- register derivation
  // (mirrors tools/scaler_coefs.py --method trilinear / anisotropic)
  // log2 for reals
  function automatic real log2r(real v);
    return $ln(v) / $ln(2.0);
  endfunction

  // Footprint -> probe count, LOD and probe step/start registers
  task automatic derive_regs();
    real sx = real'(reg_step_x) / 65536.0, sy = real'(reg_step_y) / 65536.0;
    real fmaj = (sx > sy) ? sx : sy, fmin = (sx > sy) ? sy : sx;
    real lod, d;
    if (fmaj < 1.0) fmaj = 1.0;
    if (fmin < 1.0) fmin = 1.0;
    alog2 = 0;
    if (ANISO_MAX > 0) begin
      alog2 = int'($floor(log2r(fmaj / fmin) + 0.5));
      if (alog2 > ANISO_MAX) alog2 = ANISO_MAX;
      if (alog2 < 0) alog2 = 0;
    end
    lod = log2r(fmaj / real'(1 << alog2));
    if (lod < 0.0) lod = 0.0;
    lod_reg = int'($floor(lod * 256.0 + 0.5));
    d = fmaj / real'(1 << alog2);                        // probe spacing (level-0 px)
    pstep_x = 0; pstep_y = 0;
    if (alog2 > 0) begin
      if (sx >= sy) pstep_x = int'($floor(d * 65536.0 + 0.5));
      else          pstep_y = int'($floor(d * 65536.0 + 0.5));
    end
    pstart_x = -((pstep_x * ((1 << alog2) - 1)) >>> 1);
    pstart_y = -((pstep_y * ((1 << alog2) - 1)) >>> 1);
  endtask

  // Per test: derive and program the mip registers, check level sizes
  task automatic ip_configure();
    derive_regs();
    if (lod_override >= 0) lod_reg = lod_override;
    build_pyramid();
    axil_write(12'h040, lod_reg);
    axil_write(12'h044, alog2);
    axil_write(12'h048, pstep_x);
    axil_write(12'h04C, pstep_y);
    axil_write(12'h050, pstart_x);
    axil_write(12'h054, pstart_y);
    axil_check(12'h040, lod_reg);
    axil_check(12'h044, alog2);
    axil_check(12'h050, pstart_x);
    for (int k = 0; k < LEVELS; k++) axil_check(12'h060 + 4 * k, {16'(lh[k]), 16'(lw[k])});
  endtask

  // Main test sequence
  initial begin
    tb_init("scaler_mip");      // parse plusargs, load +IMG
    reset_dut();
    axil_check(12'h024, 32'h4D49_504D);      // IP_ID "MIPM"
    axil_check(12'h058, {8'd0, 8'(PHASE_BITS), 8'(ANISO_MAX), 8'(LEVELS)});
    if (use_file) begin
      run_file_suite();              // +IMG=<file.ppm>
    end else begin
      // generated images: standard sweep plus IP-specific tests
      run_standard_suite();
      run_test(MAX_W, MAX_H, 7, 5, 1);             // ~7x downscale, deep levels
      run_test(45, 39, 11, 13, 2);                 // odd sizes, fractional LOD
      lod_override = 9 << 8; run_test(20, 16, 9, 7, 0);   // LOD beyond top level
      lod_override = 384;    run_test(20, 16, 9, 7, 1);   // explicit 1.5
      lod_override = -1;
      run_test(MAX_W, MAX_H, MAX_W, 5, 1);         // 1:8 anisotropic (y)
      run_test(MAX_W, MAX_H, 3, MAX_H, 2);         // 16:1 anisotropic (x)
      run_test(MAX_W, 36, 12, 18, 0);              // 4:1 vs 2:1
      valid_pct = 100; ready_pct = 100;
      run_test(MAX_W, MAX_H, 24, 5, 1);
      axil_write(12'h044, 15); axil_check(12'h044, ANISO_MAX);   // clamp
    end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_mip.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_mip.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_mip);
    end
  end
endmodule
