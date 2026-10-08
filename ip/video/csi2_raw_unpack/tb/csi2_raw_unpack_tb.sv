// ***************
// Filename: csi2_raw_unpack_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for csi2_raw_unpack. Four instances
//   (IN_BYTES 1, 2, 4 with OUT_W 10, and IN_BYTES 2 with OUT_W 12) unpack
//   RAW8, RAW10 and RAW12 frames whose lines end in partial words, with
//   random input gaps and output back-pressure. Every pixel value (aligned
//   to OUT_W), tuser and tlast is checked. Resync: a frame that loses a
//   payload word in the middle of a line must be followed by a frame that
//   is unpacked exactly. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module csi2_raw_unpack_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  localparam int NI = 4, MAXP = 4096;
  logic [5:0] fmt = 6'h2B;
  int gap_pct = 0, bp_pct = 0;
  bit lose = 0;                                   // drop the middle word of line 1 of frame 0
  bit check_on = 1;                               // compare pixels (off for a damaged frame)
  // Expected pixels (12-bit source values) of the current frame, raster order
  logic [11:0] src [MAXP]; int npix, line_w, nlines;

  function automatic logic [11:0] expect_px(input int idx, input int ow);
    int w; logic [11:0] v; w = (fmt == 6'h2B) ? 10 : (fmt == 6'h2C) ? 12 : 8; v = src[idx];
    return (ow >= w) ? 12'(v << (ow - w)) : 12'(v >> (w - ow));
  endfunction

  // Byte image of the frame for each instance width (same bytes for all)
  byte unsigned fb [MAXP*2]; int line_bytes;

  for (genvar g = 0; g < NI; g++) begin : g_u
    localparam int IB = (g == 0) ? 1 : (g == 1) ? 2 : (g == 2) ? 4 : 2;
    localparam int OW = (g == 3) ? 12 : 10;
    logic [IB*8-1:0] sd; logic [IB-1:0] sk; logic sl, su, sv, sr;
    logic [OW-1:0] md; logic ml, mu, mv, mr;
    int nout;
    csi2_raw_unpack #(.IN_BYTES(IB), .OUT_W(OW)) dut (.clk, .rst_n, .fmt_i(fmt),
      .s_axis_tdata(sd), .s_axis_tkeep(sk), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
      .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));
    always @(posedge clk) mr <= ($urandom_range(99) >= bp_pct);
    int nsof = 0;
    always @(posedge clk) if (rst_n && mv && mr) begin
      logic [11:0] e;
      if (mu) begin nout = 0; nsof++; end             // re-anchor on every frame start
      e = expect_px(nout, OW);
      if (check_on || nsof >= 2) begin
        check(md == e[OW-1:0], $sformatf("in%0dB out%0d: pixel %0d = %h exp %h", IB, OW, nout, md, e));
        check(mu == (nout == 0), $sformatf("in%0dB: tuser at pixel %0d", IB, nout));
        check(ml == ((nout % line_w) == line_w - 1), $sformatf("in%0dB: tlast at pixel %0d", IB, nout));
      end
      nout++;
    end
    task automatic drive(input int frames = 1);
      nout = 0; nsof = 0; sv <= 0;
      for (int f = 0; f < frames; f++)
      for (int y = 0; y < nlines; y++)
        for (int b = 0; b < line_bytes; b += IB) begin
          if (lose && f == 0 && y == 1 && b == (line_bytes / 2 / IB) * IB) continue;   // lost upstream
          while ($urandom_range(99) < gap_pct) @(posedge clk);
          for (int k = 0; k < IB; k++) begin
            sd[8*k +: 8] <= (b + k < line_bytes) ? fb[y*line_bytes + b + k] : 8'hEE;
            sk[k]        <= (b + k < line_bytes);
          end
          su <= (y == 0 && b == 0); sl <= (b + IB >= line_bytes); sv <= 1;
          @(posedge clk); while (!sr) @(posedge clk);
          sv <= 0;
        end
    endtask
  end

  task automatic run_prep(input logic [5:0] f, input int w, input int h, input int gp, input int bp);
    int bpg, ppg;
    fmt = f; line_w = w; nlines = h; npix = w * h; gap_pct = gp; bp_pct = bp;
    ppg = (f == 6'h2B) ? 4 : (f == 6'h2C) ? 2 : 1; bpg = (f == 6'h2B) ? 5 : (f == 6'h2C) ? 3 : 1;
    line_bytes = w / ppg * bpg;
    for (int i = 0; i < npix; i++) src[i] = (f == 6'h2B) ? $urandom_range(1023) : (f == 6'h2C) ? $urandom_range(4095) : $urandom_range(255);
    for (int y = 0; y < h; y++)
      for (int gi = 0; gi < w / ppg; gi++) begin
        int base, o; base = y * w + gi * ppg; o = y * line_bytes + gi * bpg;
        if (f == 6'h2B) begin
          for (int k = 0; k < 4; k++) fb[o + k] = src[base + k][9:2];
          fb[o + 4] = {src[base+3][1:0], src[base+2][1:0], src[base+1][1:0], src[base][1:0]};
        end else if (f == 6'h2C) begin
          fb[o] = src[base][11:4]; fb[o + 1] = src[base+1][11:4]; fb[o + 2] = {src[base+1][3:0], src[base][3:0]};
        end else fb[o] = src[base][7:0];
      end
  endtask

  task automatic run_frame(input logic [5:0] f, input int w, input int h, input int gp, input int bp);
    run_prep(f, w, h, gp, bp);
    fork g_u[0].drive(); g_u[1].drive(); g_u[2].drive(); g_u[3].drive(); join
    repeat (50) @(posedge clk);
    check(g_u[0].nout == npix && g_u[1].nout == npix && g_u[2].nout == npix && g_u[3].nout == npix,
          $sformatf("fmt %02h %0dx%0d: pixels out %0d %0d %0d %0d, exp %0d", f, w, h, g_u[0].nout, g_u[1].nout, g_u[2].nout, g_u[3].nout, npix));
    $display("fmt 0x%02h %0dx%0d (%0d bytes/line): %0d pixels per instance", f, w, h, line_bytes, g_u[0].nout);
  endtask

  // Frame 0 loses one word in the middle of its second line; frame 1 must be exact
  task automatic run_loss(input logic [5:0] f, input int w, input int h);
    run_prep(f, w, h, 10, 20);
    lose = 1; check_on = 0;
    fork g_u[0].drive(2); g_u[1].drive(2); g_u[2].drive(2); g_u[3].drive(2); join
    repeat (50) @(posedge clk);
    check(g_u[0].nout == npix && g_u[1].nout == npix && g_u[2].nout == npix && g_u[3].nout == npix,
          $sformatf("after a lost word: pixels of the next frame %0d %0d %0d %0d, exp %0d", g_u[0].nout, g_u[1].nout, g_u[2].nout, g_u[3].nout, npix));
    $display("fmt 0x%02h %0dx%0d: frame with a lost word, next frame exact", f, w, h);
    lose = 0; check_on = 1;
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("csi2_raw_unpack_tb.vcd"); $dumpvars(0, csi2_raw_unpack_tb); end
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    run_frame(6'h2B, 12, 4, 0, 0);         // RAW10, 15 bytes/line: partial last word for 2 and 4 bytes
    run_frame(6'h2B, 44, 6, 30, 40);      // RAW10 with gaps and back-pressure
    run_frame(6'h2C, 14, 5, 20, 20);      // RAW12, 21 bytes/line
    run_frame(6'h2A, 13, 7, 10, 50);      // RAW8, odd line length
    run_frame(6'h2B, 4, 3, 0, 70);        // smallest RAW10 line
    run_loss(6'h2B, 20, 6);               // RAW10: 25 bytes per line
    run_loss(6'h2C, 18, 5);               // RAW12: 27 bytes per line
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
