// ***************
// Filename: tb_scaler_bicubic.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for scaler_bicubic.
//   Runs the standard suite from scaler_tb_lib (identity, non-integer
//   up/down, mixed, 2x, 1x1 in/out, max size, junk before SOF, random
//   tvalid/tready stalls, full rate) and compares every output pixel
//   bit-exactly with an independent reference model (golden_pixel).
//   Plusargs: +IMG=<file.ppm> scale a PPM P6 image, +OUT_W/+OUT_H output
//   size, +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Inputs/outputs are written as PPM P6 images. Compile with
//   -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
//   Kernels: Catmull-Rom, Mitchell, cubic B-spline and Keys a=-0.75
//   (without anti-aliasing), programmed over AXI-Lite.
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
module tb_scaler_bicubic;
  // DUT configuration (also used by the reference model)
  localparam int CHANNELS   = 3;
  localparam int COMP_W     = 8;
  localparam int PIX_W      = CHANNELS * COMP_W;
  localparam int MAX_W      = `TB_MAX_W;
  localparam int MAX_H      = `TB_MAX_H;
  localparam int ADDR_W     = 14;
  localparam int TAPS       = 4;
  localparam int PHASE_BITS = 6;
  localparam int COEF_W     = 16;
  localparam int COEF_FRAC  = 14;
  localparam int PHASES     = 1 << PHASE_BITS;
  localparam int CTR        = (TAPS - 1) / 2;

  // clock, reset, AXI-Lite BFM, stream driver/checker, PPM I/O, test
  // sequencing (declares the signals connected to the DUT below)
  `include "scaler_tb_lib.svh"
  // SystemVerilog coefficient generator (fills gen_tab)
  `include "scaler_coef_gen.svh"

  // Device under test
  scaler_bicubic #(.PINGPONG(`TB_PINGPONG), .LINE_BUF(`TB_LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                     .ADDR_W(ADDR_W), .PHASE_BITS(PHASE_BITS), .COEF_W(COEF_W),
                     .COEF_FRAC(COEF_FRAC)) dut (
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

  // kernel: Keys / Mitchell-Netravali cubic
  // kernel used to derive the tables for the current test
  int  kind   = KERNEL_CUBIC;
  real kpa    = 0.0, kpb = 0.5;
  bit  aa     = 1;                 // stretch kernel when downscaling
  int  tab_h [PHASES][TAPS];     // copy of the programmed H table
  int  tab_v [PHASES][TAPS];     // copy of the programmed V table

  // ---------------------------------------------------------------- golden
  // Reference model: expected output pixel (ox, oy), computed with plain
  // integer arithmetic from img[][] and the programmed registers.
  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    longint rnd = 1 << (16 - PHASE_BITS - 1);
    longint sx = src_x(ox) + rnd, sy = src_y(oy) + rnd;
    int x0 = int'(sx >>> 16) - CTR, y0 = int'(sy >>> 16) - CTR;
    int ph = int'((sx & 64'hFFFF) >> (16 - PHASE_BITS));
    int pv = int'((sy & 64'hFFFF) >> (16 - PHASE_BITS));
    logic [PIX_W-1:0] r;
    // separable filter exactly as documented: vertical pass per window
    // column with rounding, then horizontal pass, rounding and clamping
    for (int c = 0; c < CHANNELS; c++) begin
      longint acc2 = 0;
      for (int k = 0; k < TAPS; k++) begin
        longint acc = 0;
        for (int j = 0; j < TAPS; j++)
          acc += longint'(tab_v[pv][j]) * comp(fetch(x0 + k, y0 + j), c);
        acc = (acc + (1 << (COEF_FRAC - 1))) >>> COEF_FRAC;
        acc2 += acc * longint'(tab_h[ph][k]);
      end
      acc2 = (acc2 + (1 << (COEF_FRAC - 1))) >>> COEF_FRAC;
      r[c*COMP_W +: COMP_W] = COMP_W'(clampi(int'(acc2), 0, max_comp()));
    end
    return r;
  endfunction

  // Derive a table for 'scale', write it over AXI-Lite (H at 0x1000,
  // V at 0x2000), keep a copy for the model and spot-check read-back.
  task automatic program_table(input int base, input real scale, input bit vert);
    gen_coefs(kind, kpa, kpb, TAPS, PHASE_BITS, COEF_FRAC, COEF_W, aa ? scale : 1.0);
    for (int p = 0; p < PHASES; p++)
      for (int t = 0; t < TAPS; t++) begin
        if (vert) tab_v[p][t] = gen_tab[p][t];
        else      tab_h[p][t] = gen_tab[p][t];
        axil_write(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
      end
    // spot-check read-back (sign extension)
    for (int k = 0; k < 4; k++) begin
      int p = $urandom_range(PHASES - 1, 0), t = $urandom_range(TAPS - 1, 0);
      axil_check(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
    end
  endtask

  // Per test: tables derived from the X and Y scale factors
  task automatic ip_configure();
    program_table(16'h1000, real'(in_w) / real'(out_w), 1'b0);
    program_table(16'h2000, real'(in_h) / real'(out_h), 1'b1);
  endtask

  // The tables must power up with bilinear weights
  task automatic check_default_tables();
    // reset content = bilinear
    for (int p = 0; p < PHASES; p += 13) begin
      axil_check(16'h1000 + 4 * (16 * p + CTR),     32'(((PHASES - p) << COEF_FRAC) / PHASES));
      axil_check(16'h2000 + 4 * (16 * p + CTR + 1), 32'((p << COEF_FRAC) / PHASES));
    end
  endtask

  // Main test sequence
  initial begin
    tb_init("scaler_bicubic");      // parse plusargs, load +IMG
    reset_dut();
    axil_check(12'h024, 32'h4243_5542);     // IP_ID "BCUB"
    axil_check(12'h040, {8'(COEF_FRAC), 8'(COEF_W), 8'(PHASE_BITS), 8'(TAPS)});
    check_default_tables();
    kind = KERNEL_CUBIC; kpa = 0.0; kpb = 0.5;          // Catmull-Rom
    if (use_file) begin
      run_file_suite();              // +IMG=<file.ppm>
    end else begin
      // generated images: standard sweep plus IP-specific tests
      run_standard_suite();
      kpa = 1.0/3.0; kpb = 1.0/3.0;                       // Mitchell-Netravali
      run_test(16, 12, 37, 29, 1);
      run_test(40, 30, 17, 13, 0);
      kpa = 1.0; kpb = 0.0;                               // cubic B-spline
      run_test(20, 16, 31, 23, 2);
      kpa = 0.0; kpb = 0.75; aa = 0;                      // sharp Keys a=-0.75, no AA
      run_test(40, 30, 21, 15, 2);
    end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_bicubic.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_bicubic.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_bicubic);
    end
  end
endmodule
