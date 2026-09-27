// ***************
// Filename: tb_scaler_edge_directed.sv
// Author: Paul Barcelona
// Description: Testbench for scaler_edge_directed.
//   Runs the standard suite from scaler_tb_lib (identity, non-integer
//   up/down, mixed, 2x, 1x1 in/out, max size, junk before SOF, random
//   tvalid/tready stalls, full rate) and compares every output pixel
//   bit-exactly with an independent reference model (golden_pixel).
//   Plusargs: +IMG=<file.ppm> scale a PPM P6 image, +OUT_W/+OUT_H output
//   size, +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Inputs/outputs are written as PPM P6 images. Compile with
//   -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
//   Extra tests: THRESH = 0 and 200, EDGE_EN = 0 (must equal bilinear)
//   and coverage that both diagonal modes are exercised.
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
module tb_scaler_edge_directed;
  // DUT configuration (also used by the reference model)
  localparam int CHANNELS   = 3;
  localparam int COMP_W     = 8;
  localparam int PIX_W      = CHANNELS * COMP_W;
  localparam int MAX_W      = `TB_MAX_W;
  localparam int MAX_H      = `TB_MAX_H;
  localparam int ADDR_W     = 14;
  localparam int PHASE_BITS = 8;

  // clock, reset, AXI-Lite BFM, stream driver/checker, PPM I/O, test
  // sequencing (declares the signals connected to the DUT below)
  `include "scaler_tb_lib.svh"

  // Device under test
  scaler_edge_directed #(.PINGPONG(`TB_PINGPONG), .LINE_BUF(`TB_LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W),
                         .MAX_H(MAX_H), .ADDR_W(ADDR_W), .PHASE_BITS(PHASE_BITS)) dut (
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

  int thresh  = 16;     // value programmed into THRESH
  bit edge_en = 1;      // value programmed into EDGE_CTRL.EDGE_EN
  int mode_cnt [3];     // coverage: bilinear / "\" / "/"

  // ---------------------------------------------------------------- golden
  // Reference model: expected output pixel (ox, oy), computed with plain
  // integer arithmetic from img[][] and the programmed registers.
  // Independent model: triangle interpolation written with real barycentric
  // weights scaled to integers (ONE^2 units).
  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    longint one = 1 << PHASE_BITS;
    longint rnd = 1 << (16 - PHASE_BITS - 1);
    longint sx = src_x(ox) + rnd, sy = src_y(oy) + rnd;
    int ix = int'(sx >>> 16), iy = int'(sy >>> 16);
    longint x = (sx & 64'hFFFF) >> (16 - PHASE_BITS);
    longint y = (sy & 64'hFFFF) >> (16 - PHASE_BITS);
    logic [PIX_W-1:0] p00 = fetch(ix, iy),     p01 = fetch(ix + 1, iy);
    logic [PIX_W-1:0] p10 = fetch(ix, iy + 1), p11 = fetch(ix + 1, iy + 1);
    longint d1 = 0, d2 = 0, w[4];
    logic [PIX_W-1:0] r;
    // diagonal activity over all components
    for (int c = 0; c < CHANNELS; c++) begin
      d1 += (comp(p00, c) > comp(p11, c)) ? comp(p00, c) - comp(p11, c) : comp(p11, c) - comp(p00, c);
      d2 += (comp(p01, c) > comp(p10, c)) ? comp(p01, c) - comp(p10, c) : comp(p10, c) - comp(p01, c);
    end
    if (edge_en && d1 + thresh < d2) begin
      mode_cnt[1]++;
      if (x >= y) begin w[0] = (one - x) * one; w[1] = (x - y) * one; w[2] = 0; w[3] = y * one; end
      else        begin w[0] = (one - y) * one; w[1] = 0; w[2] = (y - x) * one; w[3] = x * one; end
    end else if (edge_en && d2 + thresh < d1) begin
      mode_cnt[2]++;
      if (x + y <= one) begin w[0] = (one - x - y) * one; w[1] = x * one; w[2] = y * one; w[3] = 0; end
      else              begin w[0] = 0; w[1] = (one - y) * one; w[2] = (one - x) * one; w[3] = (x + y - one) * one; end
    end else begin
      mode_cnt[0]++;
      begin w[0] = (one - x) * (one - y); w[1] = x * (one - y); w[2] = (one - x) * y; w[3] = x * y; end
    end
    // sanity: the weights of every case must sum to ONE^2
    if (w[0] + w[1] + w[2] + w[3] != one * one) $display("ERROR: golden weights");
    for (int c = 0; c < CHANNELS; c++) begin
      longint s = w[0] * comp(p00, c) + w[1] * comp(p01, c) + w[2] * comp(p10, c)
                + w[3] * comp(p11, c) + one * one / 2;
      r[c*COMP_W +: COMP_W] = COMP_W'(s >> (2 * PHASE_BITS));
    end
    return r;
  endfunction

  // Program and read back THRESH / EDGE_CTRL
  task automatic ip_configure();
    axil_write(12'h040, thresh);
    axil_write(12'h044, edge_en);
    axil_check(12'h040, thresh);
    axil_check(12'h044, edge_en);
  endtask

  // Main test sequence
  initial begin
    tb_init("scaler_edge_directed");      // parse plusargs, load +IMG
    reset_dut();
    axil_check(12'h024, 32'h4544_4745);     // IP_ID "EDGE"
    if (use_file) begin
      run_file_suite();              // +IMG=<file.ppm>
    end else if (quick) begin
      run_quick_suite();                // +QUICK
    end else begin
      // generated images: standard sweep plus IP-specific tests
      run_standard_suite();
      thresh = 0;   run_test(20, 16, 45, 37, 1);
      thresh = 200; run_test(20, 16, 45, 37, 0);
      edge_en = 0;  run_test(20, 16, 45, 37, 1);   // must equal bilinear
      $display("coverage: bilinear=%0d diag1=%0d diag2=%0d", mode_cnt[0], mode_cnt[1], mode_cnt[2]);
      if (mode_cnt[1] == 0 || mode_cnt[2] == 0) begin
        errors++; $display("ERROR: edge modes not covered");
      end
    end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_edge_directed.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_edge_directed.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_edge_directed);
    end
  end
endmodule
