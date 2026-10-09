// ***************
// Filename: isp_window_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_window_tb testbench
//   (isp_window_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check     Counts an error and prints the message when the condition is
//               false
//     run_case
//     run_cut   A frame cut after `cut` lines, then two full frames
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 20) $display("ERROR @%0t: %s", $time, m); end
  endtask

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
