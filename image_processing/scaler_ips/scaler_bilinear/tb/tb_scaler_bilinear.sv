// ***************
// Filename: tb_scaler_bilinear.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for scaler_bilinear.
//   Runs the standard suite from scaler_tb_lib (identity, non-integer
//   up/down, mixed, 2x, 1x1 in/out, max size, junk before SOF, random
//   tvalid/tready stalls, full rate) and compares every output pixel
//   bit-exactly with an independent reference model (golden_pixel).
//   Plusargs: +IMG=<file.ppm> scale a PPM P6 image, +OUT_W/+OUT_H output
//   size, +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Inputs/outputs are written as PPM P6 images. Compile with
//   -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
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
module tb_scaler_bilinear;
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
  scaler_bilinear #(.PINGPONG(`TB_PINGPONG), .LINE_BUF(`TB_LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W),
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

  // ---------------------------------------------------------------- golden
  // Reference model: expected output pixel (ox, oy), computed with plain
  // integer arithmetic from img[][] and the programmed registers.
  // Independent integer model of the bilinear kernel.
  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    localparam longint ONE = 1 << PHASE_BITS;
    longint rnd = 1 << (16 - PHASE_BITS - 1);
    longint sx = src_x(ox) + rnd, sy = src_y(oy) + rnd;
    int ix = int'(sx >>> 16), iy = int'(sy >>> 16);       // top-left tap
    longint fx = (sx & 64'hFFFF) >> (16 - PHASE_BITS);
    longint fy = (sy & 64'hFFFF) >> (16 - PHASE_BITS);
    logic [PIX_W-1:0] r;
    // interpolate the two rows horizontally, then vertically
    for (int c = 0; c < CHANNELS; c++) begin
      longint top, bot, v;
      top = comp(fetch(ix, iy), c) * (ONE - fx) + comp(fetch(ix + 1, iy), c) * fx;
      bot = comp(fetch(ix, iy + 1), c) * (ONE - fx) + comp(fetch(ix + 1, iy + 1), c) * fx;
      v   = (top * (ONE - fy) + bot * fy + ONE * ONE / 2) >> (2 * PHASE_BITS);
      r[c*COMP_W +: COMP_W] = COMP_W'(v);
    end
    return r;
  endfunction

  // No IP-specific registers to program
  task automatic ip_configure();
  endtask

  // Main test sequence
  initial begin
    tb_init("scaler_bilinear");      // parse plusargs, load +IMG
    reset_dut();
    axil_check(12'h024, 32'h424C_494E);     // IP_ID "BLIN"
    axil_check(12'h028, {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'd2});
    if (use_file) begin
      run_file_suite();              // +IMG=<file.ppm>
    end else begin
      // generated images: standard sweep plus IP-specific tests
      run_standard_suite();
    end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_bilinear.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_bilinear.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_bilinear);
    end
  end
endmodule
