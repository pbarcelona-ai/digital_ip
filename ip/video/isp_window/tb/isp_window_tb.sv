// ***************
// Filename: isp_window_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for isp_window. Four instances
//   (N = 3 and 5, BORDER clamp and mirror) process frames of several sizes
//   (including the smallest legal one and back-to-back frames) with random
//   input gaps and random output back-pressure, a stray pixel before the
//   first start of frame (must be dropped), and a truncated frame followed
//   by full frames (the scan must restart at the early start of frame).
//   Comparisons are X-aware (===). Every window, its centre
//   coordinates, tuser and tlast are checked against a model of each border
//   rule. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module isp_window_tb;
  localparam int PW = 10, MAXW = 64, MAXH = 40, NI = 4;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 20) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic [PW-1:0] img [MAXH][MAXW];
  logic [15:0] W, H;
  int gap_pct = 0, bp_pct = 0;

  // Source pixel at (x, y) under a border rule
  function automatic int bidx(input int v, input int n, input int mirror);
    if (v < 0)  return mirror ? -v : 0;
    if (v >= n) return mirror ? 2 * (n - 1) - v : n - 1;
    return v;
  endfunction

  for (genvar g = 0; g < NI; g++) begin : g_w
    localparam int N = (g % 2) ? 5 : 3, R = (N - 1) / 2, BD = g / 2;
    logic [PW-1:0] sd; logic sl, su, sv, sr;
    logic [N*N*PW-1:0] w; logic [15:0] wx, wy; logic tl, tu, tv, tr;
    int n, total;
    isp_window #(.N(N), .PW(PW), .MAX_W(MAXW), .BORDER(BD)) dut (.clk, .rst_n, .width_i(W), .height_i(H),
      .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
      .m_axis_tdata(w), .m_x(wx), .m_y(wy), .m_axis_tlast(tl), .m_axis_tuser(tu), .m_axis_tvalid(tv), .m_axis_tready(tr));
    initial begin sv = 0; su = 0; sl = 0; sd = 0; end
    always @(posedge clk) tr <= ($urandom_range(99) >= bp_pct);
    always @(posedge clk) if (rst_n && tv && tr) begin
      int cx, cy;
      if (tu) n = 0;                                 // re-anchor on every start of frame
      cx = n % W; cy = (n / W) % H;
      check(wx === 16'(cx) && wy === 16'(cy), $sformatf("N%0d B%0d: centre %0d,%0d exp %0d,%0d", N, BD, wx, wy, cx, cy));
      check(tu == (cx == 0 && cy == 0) && tl == (cx == W - 1), $sformatf("N%0d B%0d: tuser/tlast at %0d,%0d", N, BD, cx, cy));
      for (int r = 0; r < N; r++) for (int c = 0; c < N; c++)
        check(w[(r*N + c)*PW +: PW] === img[bidx(cy - R + r, H, BD)][bidx(cx - R + c, W, BD)],
              $sformatf("N%0d B%0d: (%0d,%0d) tap r%0d c%0d", N, BD, cx, cy, r, c));
      n++; total++;
    end
    task automatic drive(input int frames, input bit stray, input int cut = 0);
      n = 0; total = 0;
      if (stray) begin sd <= 10'h3FF; su <= 0; sl <= 0; sv <= 1; @(posedge clk); while (!sr) @(posedge clk); end
      for (int f = 0; f < frames; f++)
        for (int yy = 0; yy < ((f == 0 && cut > 0) ? cut : H); yy++) for (int xx = 0; xx < W; xx++) begin
          sv <= 0; while ($urandom_range(99) < gap_pct) @(posedge clk);
          sd <= img[yy][xx]; su <= (xx == 0 && yy == 0); sl <= (xx == W - 1); sv <= 1;
          @(posedge clk); while (!sr) @(posedge clk);
        end
      sv <= 0;
    endtask
  end

  task automatic run_case(input int w, input int h, input int frames, input int gp, input int bp, input bit stray);
    W = w; H = h; gap_pct = gp; bp_pct = bp;
    for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) img[yy][xx] = $urandom_range(1023);
    fork g_w[0].drive(frames, stray); g_w[1].drive(frames, stray); g_w[2].drive(frames, stray); g_w[3].drive(frames, stray); join
    repeat (40 * w) @(posedge clk);
    check(g_w[0].total == w * h * frames && g_w[1].total == w * h * frames && g_w[2].total == w * h * frames && g_w[3].total == w * h * frames,
          $sformatf("%0dx%0d x%0d: windows %0d %0d %0d %0d, exp %0d", w, h, frames, g_w[0].total, g_w[1].total, g_w[2].total, g_w[3].total, w * h * frames));
    $display("case %0dx%0d frames=%0d gaps=%0d%% backpressure=%0d%%: %0d windows per instance", w, h, frames, gp, bp, g_w[0].total);
  endtask

  // A frame cut after `cut` lines, then two full frames: the full frames must
  // come out complete (the windows of the cut frame that were output are
  // checked too, they only use rows that arrived).
  task automatic run_cut(input int w, input int h, input int cut);
    W = w; H = h; gap_pct = 10; bp_pct = 20;
    for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) img[yy][xx] = $urandom_range(1023);
    fork g_w[0].drive(3, 0, cut); g_w[1].drive(3, 0, cut); g_w[2].drive(3, 0, cut); g_w[3].drive(3, 0, cut); join
    repeat (40 * w) @(posedge clk);
    for (int i = 0; i < NI; i++) begin
      int t, exp_min; t = (i == 0) ? g_w[0].total : (i == 1) ? g_w[1].total : (i == 2) ? g_w[2].total : g_w[3].total;
      exp_min = 2 * w * h;
      check(t >= exp_min && t < exp_min + cut * w, $sformatf("cut frame, instance %0d: %0d windows, exp %0d + part of the cut frame", i, t, exp_min));
    end
    $display("case %0dx%0d cut after %0d lines, then 2 full frames: %0d windows per instance", w, h, cut, g_w[0].total);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("isp_window_tb.vcd"); $dumpvars(0, isp_window_tb); end
    W = 8; H = 6;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    run_case(16, 12, 1, 0, 0, 1);       // stray pixel before SOF, no stalls
    run_case(3, 3, 2, 0, 0, 0);         // smallest frame for N = 5 (W, H >= R + 1)
    run_case(23, 9, 2, 30, 30, 0);      // odd width, gaps and back-pressure, back-to-back frames
    run_case(64, 40, 1, 10, 50, 0);     // full MAX_W line, heavy back-pressure
    run_case(5, 31, 1, 50, 0, 0);       // tall and narrow, slow source
    run_cut(20, 14, 6);                 // short frame, then normal frames
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
