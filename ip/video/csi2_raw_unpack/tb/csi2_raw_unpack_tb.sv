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
//   The test tasks are in tests/csi2_raw_unpack_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module csi2_raw_unpack_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  localparam int NI = 4, MAXP = 4096;
  logic [5:0] fmt = 6'h2B;
  int gap_pct = 0, bp_pct = 0;
  bit lose = 0;                                   // drop the middle word of line 1 of frame 0
  bit check_on = 1;                               // compare pixels (off for a damaged frame)
  // Expected pixels (12-bit source values) of the current frame, raster order
  logic [11:0] src [MAXP];
  int npix, line_w, nlines;

  function automatic logic [11:0] expect_px(input int idx, input int ow);
    int w;
    logic [11:0] v;
    w = (fmt == 6'h2B) ? 10 : (fmt == 6'h2C) ? 12 : 8;
    v = src[idx];
    return (ow >= w) ? 12'(v << (ow - w)) : 12'(v >> (w - ow));
  endfunction

  // Byte image of the frame for each instance width (same bytes for all)
  byte unsigned fb [MAXP*2];
  int line_bytes;

  for (genvar g = 0; g < NI; g++) begin : g_u
    localparam int IB = (g == 0) ? 1 : (g == 1) ? 2 : (g == 2) ? 4 : 2;
    localparam int OW = (g == 3) ? 12 : 10;
    axis_if #(.DATA_W(IB*8), .USER_W(1), .KEEP_W(IB)) s_axis ();
    axis_if #(.DATA_W(OW), .USER_W(1)) m_axis ();
    int nout;
    csi2_raw_unpack #(
      .IN_BYTES(IB),
      .OUT_W(OW)
    ) dut (
      .clk,
      .rst_n,
      .fmt_i(fmt),
      .s_axis(s_axis),
      .m_axis(m_axis)
    );
    always @(posedge clk) m_axis.tready <= ($urandom_range(99) >= bp_pct);
    int nsof = 0;
    always @(posedge clk) if (rst_n && m_axis.tvalid && m_axis.tready) begin
      logic [11:0] e;
      if (m_axis.tuser) begin // re-anchor on every frame start
        nout = 0;
        nsof++;
      end
      e = expect_px(nout, OW);
      if (check_on || nsof >= 2) begin
        check(m_axis.tdata == e[OW-1:0], $sformatf("in%0dB out%0d: pixel %0d = %h exp %h", IB, OW, nout, m_axis.tdata, e));
        check(m_axis.tuser == (nout == 0), $sformatf("in%0dB: tuser at pixel %0d", IB, nout));
        check(m_axis.tlast == ((nout % line_w) == line_w - 1), $sformatf("in%0dB: tlast at pixel %0d", IB, nout));
      end
      nout++;
    end
    task automatic drive(input int frames = 1);
      nout = 0;
      nsof = 0;
      s_axis.tvalid <= 0;
      for (int f = 0; f < frames; f++)
      for (int y = 0; y < nlines; y++)
        for (int b = 0; b < line_bytes; b += IB) begin
          if (lose && f == 0 && y == 1 && b == (line_bytes / 2 / IB) * IB) continue;   // lost upstream
          while ($urandom_range(99) < gap_pct) begin
            s_axis.tvalid <= 0;
            @(posedge clk);
          end
          for (int k = 0; k < IB; k++) begin
            s_axis.tdata[8*k +: 8] <= (b + k < line_bytes) ? fb[y*line_bytes + b + k] : 8'hEE;
            s_axis.tkeep[k]        <= (b + k < line_bytes);
          end
          s_axis.tuser <= (y == 0 && b == 0);
          s_axis.tlast <= (b + IB >= line_bytes);
          s_axis.tvalid <= 1;
          @(posedge clk);
          while (!s_axis.tready) @(posedge clk);
        end
      s_axis.tvalid <= 0;   // only here and in gaps: no sv <= 0 / sv <= 1 pair in one time step (NBA order)
    endtask
  end

  // test tasks: tests/csi2_raw_unpack_tests.sv
  `include "csi2_raw_unpack_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("csi2_raw_unpack_tb.vcd");
      $dumpvars(0, csi2_raw_unpack_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    run_frame(6'h2B, 12, 4, 0, 0);         // RAW10, 15 bytes/line: partial last word for 2 and 4 bytes
    run_frame(6'h2B, 44, 6, 30, 40);      // RAW10 with gaps and back-pressure
    run_frame(6'h2C, 14, 5, 20, 20);      // RAW12, 21 bytes/line
    run_frame(6'h2A, 13, 7, 10, 50);      // RAW8, odd line length
    run_frame(6'h2B, 4, 3, 0, 70);        // smallest RAW10 line
    run_loss(6'h2B, 20, 6);               // RAW10: 25 bytes per line
    run_loss(6'h2C, 18, 5);               // RAW12: 27 bytes per line
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
