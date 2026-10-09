// ***************
// Filename: isp_demosaic_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_demosaic_tb testbench
//   (isp_demosaic_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
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

  task automatic frame(input int w, input int h, input logic [1:0] p, input bit bypass, input bit is_ramp);
    W = w;
    H = h;
    cfa = p;
    by = bypass;
    nout = 0;
    ramp = is_ramp;
    max_err = 0;
    max_err_in = 0;
    for (int i = 0; i < w * h; i++) begin
      int x, y, c;
      x = i % w;
      y = i / w;
      c = {y[0] ^ p[1], x[0] ^ p[0]};
      truth[i][0] = 100 + 9 * x + 4 * y;
      truth[i][1] = 300 + 5 * x + 7 * y;
      truth[i][2] = 50 + 3 * x + 11 * y;
      if (is_ramp) img[i] = (c == 0) ? truth[i][0] : (c == 3) ? truth[i][2] : truth[i][1];
      else         img[i] = $urandom_range(1023);
    end
    for (int i = 0; i < w * h; i++) begin
      int x, y, c, r, g, b, cr, dg, hz, vt;
      x = i % w;
      y = i / w;
      c = {y[0] ^ p[1], x[0] ^ p[0]};
      cr = (px(x, y-1) + px(x, y+1) + px(x-1, y) + px(x+1, y) + 2) >> 2;
      dg = (px(x-1, y-1) + px(x+1, y-1) + px(x-1, y+1) + px(x+1, y+1) + 2) >> 2;
      hz = (px(x-1, y) + px(x+1, y) + 1) >> 1;
      vt = (px(x, y-1) + px(x, y+1) + 1) >> 1;
      case (c)
        0: begin
          r = img[i];
          g = cr;
          b = dg;
        end
        3: begin
          r = dg;
          g = cr;
          b = img[i];
        end
        1: begin
          r = hz;
          g = img[i];
          b = vt;
        end
        default: begin
          r = vt;
          g = img[i];
          b = hz;
        end
      endcase
      if (bypass) begin
        r = img[i];
        g = img[i];
        b = img[i];
      end
      exp_px[i] = {PW'(b), PW'(g), PW'(r)};
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
      if (i == w * h / 2) begin
        cfa <= ~p;
        by <= ~bypass;
      end
    end
    sv <= 0;
    repeat (6 * w) @(posedge clk);
    check(nout == w * h, $sformatf("%0dx%0d: %0d pixels out", w, h, nout));
  endtask
