// ***************
// Filename: tb_banked_framebuf.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for banked_framebuf.
//   fb_checker instances for TAPS = 1, 2, 3, 4, 6 and 8 each write random
//   images of random size, then issue random window reads (including
//   windows hanging off every edge) with random read stalls. Every tap is
//   compared with a clamp-to-edge reference after the 2-cycle latency.
//   Plusargs: +VCD=<file> waveform file, +NO_VCD disables dumping.
// Date: 2026-09-26

`timescale 1ns/1ps

// fb_checker: drives one banked_framebuf instance with a given TAPS and
// checks every window it returns. errors/checks are reported to the top
// and done is raised when all iterations are finished.
module fb_checker #(parameter int TAPS = 4, parameter int MAX_W = 29, parameter int MAX_H = 23,
                    parameter int NBUF = 1, parameter int RING = 0)
                   (input logic clk, output int errors, output int checks, output int done);
  localparam int PIX_W = 12;                      // arbitrary pixel width
  logic                        wr_en = 0, rd_adv = 0, wr_buf = 0, rd_buf = 0;
  logic [15:0]                 wr_x = 0, wr_y = 0, img_w = 1, img_h = 1;
  logic [PIX_W-1:0]            wr_data = 0;
  logic signed [17:0]          rd_x0 = 0, rd_y0 = 0;
  logic [TAPS*TAPS*PIX_W-1:0]  rd_win;
  logic [PIX_W-1:0]            ref_img [2][MAX_H][MAX_W];  // written image per buffer

  // Device under test
  banked_framebuf #(.PIX_W(PIX_W), .TAPS(TAPS), .MAX_W(MAX_W), .MAX_H(MAX_H),
                    .NBUF(NBUF), .RING(RING)) dut (.*);

  // clamp v into [0, hi]
  function automatic int cl(int v, int hi); return v < 0 ? 0 : (v > hi ? hi : v); endfunction

  // expected-window queue (pipeline model driven by rd_adv)
  int qx [3], qy [3], qb [3]; bit qv [3];
  int w, h;

  task automatic write_row(input int b, input int y);
    for (int x = 0; x < w; x++) begin
      @(negedge clk);
      wr_en = 1; wr_buf = b; wr_x = x; wr_y = y; wr_data = PIX_W'($urandom);
      ref_img[b][y][x] = wr_data;
    end
    @(negedge clk) wr_en = 0;
  endtask

  // one read cycle: issue a window at (x0, y0) of buffer b (issue = 0 only
  // flushes the pipeline), then compare the window that comes out
  task automatic read_cycle(input bit issue, input int b, input int x0, input int y0,
                            input bit adv);
    @(negedge clk);
    rd_adv = adv; rd_buf = b; rd_x0 = 18'(x0); rd_y0 = 18'(y0);
    @(posedge clk);
    if (adv) begin
      qv[2] = qv[1]; qx[2] = qx[1]; qy[2] = qy[1]; qb[2] = qb[1];
      qv[1] = issue; qx[1] = x0;    qy[1] = y0;    qb[1] = b;
    end
    #1;
    if (qv[2]) begin
      for (int j = 0; j < TAPS; j++)
        for (int i = 0; i < TAPS; i++) begin
          logic [PIX_W-1:0] e;
          e = ref_img[qb[2]][cl(qy[2] + j, h - 1)][cl(qx[2] + i, w - 1)];
          checks++;
          if (rd_win[((j*TAPS)+i)*PIX_W +: PIX_W] !== e) begin
            errors++;
            if (errors < 6)
              $display("ERROR: TAPS=%0d NBUF=%0d RING=%0d buf%0d win(%0d,%0d) tap(%0d,%0d) got %0h exp %0h",
                       TAPS, NBUF, RING, qb[2], qx[2], qy[2], j, i,
                       rd_win[((j*TAPS)+i)*PIX_W +: PIX_W], e);
          end
        end
      qv[2] = 0;
    end
  endtask

  task automatic flush();
    read_cycle(0, 0, 0, 0, 1);
    read_cycle(0, 0, 0, 0, 1);
    @(negedge clk) rd_adv = 0;
  endtask

  initial begin
    errors = 0; checks = 0; done = 0;
    for (int k = 0; k < 3; k++) qv[k] = 0;
    for (int it = 0; it < 6; it++) begin
      w = (it == 0) ? MAX_W : $urandom_range(MAX_W, 1);
      h = (it == 1) ? MAX_H : $urandom_range(MAX_H, 1);
      if (it == 2) begin w = 1; h = 1; end
      @(negedge clk); img_w = w; img_h = h;
      if (RING == 0) begin
        // full frame(s): write every buffer, then random reads of random
        // buffers, origins up to TAPS pixels outside the image, random stalls
        for (int b = 0; b < NBUF; b++)
          for (int y = 0; y < h; y++) write_row(b, y);
        for (int n = 0; n < 600; n++)
          read_cycle(1, $urandom_range(NBUF - 1, 0),
                     int'($urandom_range(w + TAPS, 0)) - TAPS,
                     int'($urandom_range(h + TAPS, 0)) - TAPS,
                     $urandom_range(3, 0) != 0);
        flush();
      end else begin
        // line buffer: after each new row r only windows whose (clamped)
        // rows lie in the last RING rows written are valid; read those
        for (int r = 0; r < h; r++) begin
          int lo, hi;
          write_row(0, r);
          lo = (r - RING + 1 <= 0) ? -TAPS : r - RING + 1;
          hi = (r == h - 1) ? h : r - TAPS + 1;          // bottom rows clamp
          if (hi >= lo) begin
            for (int n = 0; n < 40; n++)
              read_cycle(1, 0, int'($urandom_range(w + TAPS, 0)) - TAPS,
                         lo + int'($urandom_range(hi - lo, 0)), $urandom_range(3, 0) != 0);
            flush();                                      // finish before overwriting
          end
        end
      end
    end
    done = 1;
  end
endmodule

module tb_banked_framebuf;
  logic clk = 0; always #5 clk = ~clk;
  localparam int N = 10;
  int e [N], c [N], d [N];
  fb_checker #(.TAPS(1)) u1 (.clk, .errors(e[0]), .checks(c[0]), .done(d[0]));
  fb_checker #(.TAPS(2)) u2 (.clk, .errors(e[1]), .checks(c[1]), .done(d[1]));
  fb_checker #(.TAPS(3)) u3 (.clk, .errors(e[2]), .checks(c[2]), .done(d[2]));
  fb_checker #(.TAPS(4)) u4 (.clk, .errors(e[3]), .checks(c[3]), .done(d[3]));
  fb_checker #(.TAPS(6)) u6 (.clk, .errors(e[4]), .checks(c[4]), .done(d[4]));
  fb_checker #(.TAPS(8), .MAX_W(40), .MAX_H(17)) u8 (.clk, .errors(e[5]), .checks(c[5]), .done(d[5]));
  // double buffer (ping-pong)
  fb_checker #(.TAPS(2), .NBUF(2)) up2 (.clk, .errors(e[6]), .checks(c[6]), .done(d[6]));
  fb_checker #(.TAPS(6), .NBUF(2)) up6 (.clk, .errors(e[7]), .checks(c[7]), .done(d[7]));
  // line buffer (ring of RING rows)
  fb_checker #(.TAPS(4), .RING(8))  ur4 (.clk, .errors(e[8]), .checks(c[8]), .done(d[8]));
  fb_checker #(.TAPS(1), .RING(4))  ur1 (.clk, .errors(e[9]), .checks(c[9]), .done(d[9]));
  initial begin
    int te, tc;
    te = 0; tc = 0;
    for (int i = 0; i < N; i++) wait (d[i]);
    for (int i = 0; i < N; i++) begin te += e[i]; tc += c[i]; end
    if (te == 0) $display("TB_RESULT: PASS  checks=%0d", tc);
    else         $display("TB_RESULT: FAIL  checks=%0d errors=%0d", tc, te);
    $finish;
  end
  initial begin #50_000_000; $display("TB_RESULT: FAIL (timeout)"); $finish; end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_banked_framebuf.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_banked_framebuf.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_banked_framebuf);
    end
  end
endmodule
