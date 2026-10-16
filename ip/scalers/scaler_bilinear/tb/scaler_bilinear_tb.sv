// ***************
// Filename: tb_scaler_bilinear.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for scaler_bilinear.
//   Runs the standard suite from scaler_tb_lib (identity, non-integer
//   up/down, mixed, 2x, 1x1 in/out, max size, junk before SOF, random
//   tvalid/tready stalls, full rate) and compares every output pixel
//   bit-exactly with an independent reference model (golden_pixel).
//   Plusargs: +IMG=<file.ppm> scale a PPM P6 image, +OUT_W/+OUT_H output
//   size, +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Inputs/outputs are written as PPM P6 images. Compile with
//   -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
//   The test tasks are in tests/scaler_bilinear_tests.sv (`included).
// Date: 2026-10-16

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
  axil_if #(.ADDR_W(ADDR_W)) dut_s_axil ();
  assign dut_s_axil.awaddr = awaddr;
  assign dut_s_axil.awvalid = awvalid;
  assign awready = dut_s_axil.awready;
  assign dut_s_axil.wdata = wdata;
  assign dut_s_axil.wstrb = wstrb;
  assign dut_s_axil.wvalid = wvalid;
  assign wready = dut_s_axil.wready;
  assign bresp = dut_s_axil.bresp;
  assign bvalid = dut_s_axil.bvalid;
  assign dut_s_axil.bready = bready;
  assign dut_s_axil.araddr = araddr;
  assign dut_s_axil.arvalid = arvalid;
  assign arready = dut_s_axil.arready;
  assign rdata = dut_s_axil.rdata;
  assign rresp = dut_s_axil.rresp;
  assign rvalid = dut_s_axil.rvalid;
  assign dut_s_axil.rready = rready;
  axis_if #(.DATA_W(CHANNELS * COMP_W)) dut_s_axis ();
  assign dut_s_axis.tdata = s_tdata;
  assign dut_s_axis.tvalid = s_tvalid;
  assign s_tready = dut_s_axis.tready;
  assign dut_s_axis.tuser = s_tuser;
  assign dut_s_axis.tlast = s_tlast;
  axis_if #(.DATA_W(CHANNELS * COMP_W)) dut_m_axis ();
  assign m_tdata = dut_m_axis.tdata;
  assign m_tvalid = dut_m_axis.tvalid;
  assign dut_m_axis.tready = m_tready;
  assign m_tuser = dut_m_axis.tuser;
  assign m_tlast = dut_m_axis.tlast;
  scaler_bilinear #(.PINGPONG(`TB_PINGPONG), .LINE_BUF(`TB_LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W),
                    .MAX_H(MAX_H), .ADDR_W(ADDR_W), .PHASE_BITS(PHASE_BITS)) dut (
    .clk,
    .rst_n,
    .s_axil(dut_s_axil),
    .s_axis(dut_s_axis),
    .m_axis(dut_m_axis)
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

  // test tasks: tests/scaler_bilinear_tests.sv
  `include "scaler_bilinear_tests.sv"

  // Main test sequence
  initial begin
    tb_init("scaler_bilinear");      // parse plusargs, load +IMG
    reset_dut();
    axil_check(12'h024, 32'h424C_494E);     // IP_ID "BLIN"
    check_id_block('h0, 32'h424C_494E);      // ID block: ID, VERSION, DATE
    axil_read_err('h050);                    // no IP-specific registers (EXT_WORDS = 0): SLVERR
    axil_write_err('h050, 32'h1);
    axil_check(12'h028, {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'd2});
    if (use_file) begin
      run_file_suite();              // +IMG=<file.ppm>
    end else if (quick) begin
      run_quick_suite();                // +QUICK
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
