// ***************
// Filename: tb_sharpen_cas.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sharpen_cas.
//   Runs the same-size filter suite from scaler_tb_lib (single pixel, single
//   row/column, max size, junk before SOF, full rate, heavy back-pressure)
//   at several SHARPNESS settings and in BYPASS, comparing every output
//   pixel bit-exactly with an independent reference model of the CAS
//   arithmetic. AXI-Lite and AXI-Stream protocol checkers run throughout.
//   Plusargs: +IMG=<file.ppm> sharpen a PPM P6 image, +SHARP=<0..256>,
//   +OUTDIR=<dir>, +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Compile with -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40.
// Date: 2026-09-26

`timescale 1ns/1ps

`ifndef TB_MAX_W
`define TB_MAX_W 48
`endif
`ifndef TB_MAX_H
`define TB_MAX_H 40
`endif
module tb_sharpen_cas;
  localparam int CHANNELS = 3;
  localparam int COMP_W   = 8;
  localparam int PIX_W    = CHANNELS * COMP_W;
  localparam int MAX_W    = `TB_MAX_W;
  localparam int MAX_H    = `TB_MAX_H;
  localparam int ADDR_W   = 8;
  localparam int M        = (1 << COMP_W) - 1;

  `include "scaler_tb_lib.svh"

  sharpen_cas #(.CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .ADDR_W(ADDR_W)) dut (
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

  int sharp  = 128;
  bit bypass = 0;

  // ---------------------------------------------------------------- reference model
  // Written from the specification in sharpen_cas.sv / docs, independently of
  // the RTL (tables computed here with plain integer arithmetic).
  function automatic int ref_isqrt_round(input int v);
    int r;
    r = 0;
    while ((r + 1) * (r + 1) <= v) r++;
    if (v - r * r > r) r++;
    return r;
  endfunction

  function automatic int px(int x, int y, int c);
    return comp(fetch(x, y), c);
  endfunction

  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    logic [PIX_W-1:0] r;
    int gain;
    gain = (65536 + (1024 - 3 * sharp) / 2) / (1024 - 3 * sharp);
    for (int c = 0; c < CHANNELS; c++) begin
      int e, n, w, ea, s, mn5, mx5, mn9, mx9, head, amp, sq, k, v;
      longint rc;
      e  = px(ox, oy, c);
      n  = px(ox, oy - 1, c);  s  = px(ox, oy + 1, c);
      w  = px(ox - 1, oy, c);  ea = px(ox + 1, oy, c);
      mn5 = e; mx5 = e;
      mn5 = imin(n, mn5); mx5 = imax(n, mx5); mn5 = imin(s, mn5); mx5 = imax(s, mx5);
      mn5 = imin(w, mn5); mx5 = imax(w, mx5); mn5 = imin(ea, mn5); mx5 = imax(ea, mx5);
      mn9 = mn5; mx9 = mx5;
      mn9 = imin(px(ox - 1, oy - 1, c), mn9); mx9 = imax(px(ox - 1, oy - 1, c), mx9);
      mn9 = imin(px(ox + 1, oy - 1, c), mn9); mx9 = imax(px(ox + 1, oy - 1, c), mx9);
      mn9 = imin(px(ox - 1, oy + 1, c), mn9); mx9 = imax(px(ox - 1, oy + 1, c), mx9);
      mn9 = imin(px(ox + 1, oy + 1, c), mn9); mx9 = imax(px(ox + 1, oy + 1, c), mx9);
      head = mn5 + mn9;
      if (2 * M - (mx5 + mx9) < head) head = 2 * M - (mx5 + mx9);
      if (mx5 + mx9 == 0) amp = 0;
      else begin
        rc  = ((64'd1 << 24) + (mx5 + mx9) / 2) / (mx5 + mx9);
        amp = int'((longint'(head) * rc + 32768) >> 16);
        if (amp > 256) amp = 256;
      end
      sq = ref_isqrt_round(amp * 256);
      k  = (sq * gain + 128) >>> 8;
      v  = e + ((k * (4 * e - n - s - w - ea) + 128) >>> 8);
      if (bypass) v = e;
      r[c*COMP_W +: COMP_W] = COMP_W'(clampi(v, 0, M));
    end
    return r;
  endfunction

  // Min/max helpers (functions: they are called from golden_pixel)
  function automatic int imin(input int a, input int b); return (a < b) ? a : b; endfunction
  function automatic int imax(input int a, input int b); return (a > b) ? a : b; endfunction

  task automatic ip_configure();
    axil_write(12'h040, sharp);
    axil_check(12'h040, sharp);
    ctrl_bits = {30'd0, bypass, 1'b0};             // BYPASS, written together with ENABLE
  endtask

  initial begin
    tb_init("sharpen_cas");
    lib_filter = 1'b1;
    if ($value$plusargs("SHARP=%d", sharp)) ;
    reset_dut();
    axil_check(12'h024, 32'h5348_5250);           // IP_ID "SHRP"
    axil_check(12'h028, {8'd0, 8'(COMP_W), 8'(CHANNELS), 8'd3});
    axil_check(12'h02C, 32'(MAX_W));
    axil_check(12'h040, 128);                     // reset SHARPNESS
    if (use_file) begin
      run_file_suite();
    end else if (quick) begin
      run_quick_filter_suite();                // +QUICK
    end else begin
      run_filter_suite();
      sharp = 0;   run_test(24, 18, 24, 18, 0);
      sharp = 256; run_test(24, 18, 24, 18, 1);
      sharp = 256; run_test(MAX_W, MAX_H, MAX_W, MAX_H, 0);
      axil_write(12'h040, 999); axil_check(12'h040, 256);   // clamp
      sharp = 200; bypass = 1; run_test(17, 11, 17, 11, 1);
      bypass = 0;
    end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_sharpen_cas.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_sharpen_cas.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_sharpen_cas);
    end
  end
endmodule
