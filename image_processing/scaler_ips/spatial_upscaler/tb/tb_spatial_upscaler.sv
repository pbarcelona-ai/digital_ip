// ***************
// Filename: tb_spatial_upscaler.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for spatial_upscaler (Lanczos-3
//   scaler followed by contrast-adaptive sharpening).
//   For every test the reference model first computes the complete Lanczos
//   output image (mid[][]) from the programmed coefficient tables, then the
//   CAS output from mid[][]; every pixel of the DUT output is compared
//   bit-exactly. Runs the standard scaler suite at several sharpness
//   settings. AXI-Lite and AXI-Stream protocol checkers run throughout.
//   Plusargs: +IMG=<file.ppm>, +OUT_W/+OUT_H, +SHARP=<0..256>, +OUTDIR=<dir>,
//   +NO_PPM, +VCD=<file>, +NO_VCD, +TIMEOUT_MS=<n>.
//   Compile with -DTB_MAX_W/-DTB_MAX_H for images larger than 48x40; the
//   output may be up to twice the maximum input size in each direction.
// Date: 2026-09-26

`timescale 1ns/1ps

// Frame-store mode of the scaler stage: -DTB_PINGPONG=1 or -DTB_LINE_BUF=1
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
module tb_spatial_upscaler;
  localparam int CHANNELS   = 3;
  localparam int COMP_W     = 8;
  localparam int PIX_W      = CHANNELS * COMP_W;
  localparam int MAX_W      = `TB_MAX_W;
  localparam int MAX_H      = `TB_MAX_H;
  localparam int OUT_MAX_W  = 2 * MAX_W;
  localparam int OUT_MAX_H  = 2 * MAX_H;
  localparam int ADDR_W     = 15;
  localparam int TAPS       = 6;
  localparam int PHASE_BITS = 6;
  localparam int COEF_W     = 16;
  localparam int COEF_FRAC  = 14;
  localparam int PHASES     = 1 << PHASE_BITS;
  localparam int CTR        = (TAPS - 1) / 2;
  localparam int M          = (1 << COMP_W) - 1;

  `include "scaler_tb_lib.svh"
  `include "scaler_coef_gen.svh"

  spatial_upscaler #(.PINGPONG(`TB_PINGPONG), .LINE_BUF(`TB_LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                     .OUT_MAX_W(OUT_MAX_W), .ADDR_W(ADDR_W)) dut (
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

  int  sharp = 128;
  int  tab_h [PHASES][TAPS];
  int  tab_v [PHASES][TAPS];
  logic [PIX_W-1:0] mid [OUT_MAX_H][OUT_MAX_W];

  // ---------------------------------------------------------------- stage 1 model
  function automatic logic [PIX_W-1:0] lanczos_pixel(int ox, int oy);
    longint rnd = 1 << (16 - PHASE_BITS - 1);
    longint sx = src_x(ox) + rnd, sy = src_y(oy) + rnd;
    int x0 = int'(sx >>> 16) - CTR, y0 = int'(sy >>> 16) - CTR;
    int ph = int'((sx & 64'hFFFF) >> (16 - PHASE_BITS));
    int pv = int'((sy & 64'hFFFF) >> (16 - PHASE_BITS));
    logic [PIX_W-1:0] r;
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
      r[c*COMP_W +: COMP_W] = COMP_W'(clampi(int'(acc2), 0, M));
    end
    return r;
  endfunction

  // ---------------------------------------------------------------- stage 2 model
  function automatic int mc(int x, int y, int c);
    return comp(mid[clampi(y, 0, out_h - 1)][clampi(x, 0, out_w - 1)], c);
  endfunction

  function automatic int ref_isqrt_round(input int v);
    int r;
    r = 0;
    while ((r + 1) * (r + 1) <= v) r++;
    if (v - r * r > r) r++;
    return r;
  endfunction

  task automatic mm(input int v, inout int mn, inout int mx);
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  endtask

  function automatic logic [PIX_W-1:0] golden_pixel(int ox, int oy);
    logic [PIX_W-1:0] r;
    int gain;
    gain = (65536 + (1024 - 3 * sharp) / 2) / (1024 - 3 * sharp);
    for (int c = 0; c < CHANNELS; c++) begin
      int e, n, w, ea, s, mn5, mx5, mn9, mx9, head, amp, sq, k, v;
      longint rc;
      e = mc(ox, oy, c); n = mc(ox, oy - 1, c); s = mc(ox, oy + 1, c);
      w = mc(ox - 1, oy, c); ea = mc(ox + 1, oy, c);
      mn5 = e; mx5 = e;
      mm(n, mn5, mx5); mm(s, mn5, mx5); mm(w, mn5, mx5); mm(ea, mn5, mx5);
      mn9 = mn5; mx9 = mx5;
      mm(mc(ox - 1, oy - 1, c), mn9, mx9); mm(mc(ox + 1, oy - 1, c), mn9, mx9);
      mm(mc(ox - 1, oy + 1, c), mn9, mx9); mm(mc(ox + 1, oy + 1, c), mn9, mx9);
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
      r[c*COMP_W +: COMP_W] = COMP_W'(clampi(v, 0, M));
    end
    return r;
  endfunction

  // ---------------------------------------------------------------- configuration
  task automatic program_table(input int base, input real scale, input bit vert);
    gen_coefs(KERNEL_LANCZOS, 3.0, 0.0, TAPS, PHASE_BITS, COEF_FRAC, COEF_W, scale);
    for (int p = 0; p < PHASES; p++)
      for (int t = 0; t < TAPS; t++) begin
        if (vert) tab_v[p][t] = gen_tab[p][t];
        else      tab_h[p][t] = gen_tab[p][t];
        axil_write(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
      end
  endtask

  task automatic ip_configure();
    if (out_w > OUT_MAX_W || out_h > OUT_MAX_H) begin
      $display("TB_RESULT: FAIL (output %0dx%0d exceeds testbench limit %0dx%0d)",
               out_w, out_h, OUT_MAX_W, OUT_MAX_H);
      $finish;
    end
    program_table(16'h1000, real'(in_w) / real'(out_w), 1'b0);
    program_table(16'h2000, real'(in_h) / real'(out_h), 1'b1);
    axil_write(16'h4008, {16'(out_h), 16'(out_w)});   // sharpener size = scaler output
    axil_write(16'h4040, sharp);
    axil_write(16'h4004, 32'hE);
    axil_write(16'h4000, 32'h1);                      // enable sharpener
    axil_check(16'h4008, {16'(out_h), 16'(out_w)});
    for (int y = 0; y < out_h; y++)                   // stage-1 reference image
      for (int x = 0; x < out_w; x++)
        mid[y][x] = lanczos_pixel(x, y);
  endtask

  initial begin
    logic [31:0] fc;
    tb_init("spatial_upscaler");
    // the sharpener drains ~2 lines after the scaler finishes a frame, so the
    // next frame's input may overlap the tail of the output in frame mode
    mon_strict_overlap = 1'b0;
    if ($value$plusargs("SHARP=%d", sharp)) ;
    reset_dut();
    axil_check(16'h0024, 32'h4C41_4E43);    // scaler IP_ID "LANC"
    axil_check(16'h4024, 32'h5348_5250);    // sharpener IP_ID "SHRP"
    if (use_file) begin
      run_file_suite();
    end else begin
      run_standard_suite();
      sharp = 0;   run_test(20, 15, 40, 30, 1);
      sharp = 256; run_test(20, 15, 40, 30, 2);
      sharp = 256; run_test(MAX_W, MAX_H, 2 * MAX_W, 2 * MAX_H, 0);   // largest output
    end
    axil_read(16'h4020, fc);
    checks++;
    if (fc != frames_total) begin errors++; $display("ERROR: sharpener FRAME_CNT %0d != %0d", fc, frames_total); end
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_spatial_upscaler.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_spatial_upscaler.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_spatial_upscaler);
    end
  end
endmodule
