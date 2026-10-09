// ***************
// Filename: isp_dpc_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_dpc_tb testbench (isp_dpc_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic frame(input int w, input int h, input int t, input bit bypass);
    int exp_corr, nplant;
    exp_corr = 0;
    W = w;
    H = h;
    thr = t;
    by = bypass;
    nout = 0;
    ncorr = 0;
    for (int i = 0; i < w * h; i++) begin                       // smooth gradient per CFA colour
      int x, y;
      x = i % w;
      y = i / w;
      img[i] = 200 + 8 * x + 5 * y + ((x % 2) ? 40 : 0) + ((y % 2) ? 25 : 0) + $urandom_range(6);
    end
    img[0] = 1023; // corners
    img[w - 1] = 0;
    img[(h - 1) * w] = 1000;
    img[w * h - 1] = 3;
    nplant = 0;                                                                       // isolated interior
    for (int k = 0; 2 + 5 * k < w - 2; k++) begin                                     // defects, 5 apart
      int px_, py_;
      px_ = 2 + 5 * k;
      py_ = 2 + (k % 2) * 3;
      if (py_ < h - 2) begin
        img[py_ * w + px_] = (k % 2) ? 1023 : 0;
        nplant++;
      end
    end
    for (int i = 0; i < w * h; i++) begin
      int x, y, mx, mn, c;
      x = i % w;
      y = i / w;
      c = img[i];
      mx = 0;
      mn = 1023;
      for (int dy = -2; dy <= 2; dy += 2) for (int dx = -2; dx <= 2; dx += 2)
        if (!(dx == 0 && dy == 0)) begin
          if (px(x + dx, y + dy) > mx) mx = px(x + dx, y + dy);
          if (px(x + dx, y + dy) < mn) mn = px(x + dx, y + dy);
        end
      exp_px[i] = c;
      if (!bypass && c > mx + t)      begin
        exp_px[i] = mx;
        exp_corr++;
      end
      else if (!bypass && c + t < mn) begin
        exp_px[i] = mn;
        exp_corr++;
      end
    end
    for (int i = 0; i < w * h; i++) begin
      while ($urandom_range(99) < gap_pct) begin
        sv <= 0;
        @(posedge clk);
      end
      sd <= img[i];
      su <= (i == 0);
      sl <= (i % w == w - 1);
      sv <= 1;
      @(posedge clk);
      while (!sr) @(posedge clk);
      if (i == w * h / 2) by <= ~bypass;
    end
    sv <= 0;
    repeat (8 * w) @(posedge clk);
    check(nout == w * h, $sformatf("%0dx%0d: %0d pixels out", w, h, nout));
    check(ncorr == exp_corr, $sformatf("%0dx%0d: %0d corrections, exp %0d", w, h, ncorr, exp_corr));
    if (!bypass && t <= 60) check(exp_corr >= nplant, $sformatf("%0dx%0d: only %0d of %0d isolated defects corrected", w, h, exp_corr, nplant));
    $display("frame %0dx%0d thr=%0d bypass=%0b: %0d pixels corrected", w, h, t, bypass, ncorr);
  endtask
