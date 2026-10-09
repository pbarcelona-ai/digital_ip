// ***************
// Filename: isp_blc_wb_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_blc_wb_tb testbench
//   (isp_blc_wb_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic frame(input int w, input int h, input logic [1:0] p, input bit bb, input bit wbb);
    logic [PW-1:0] off [4]; logic [11:0] g3 [3];
    W = w; H = h; nout = 0;
    cfa = p; blc_by = bb; wb_by = wbb;
    for (int c = 0; c < 4; c++) begin off[c] = $urandom_range(120); blc[c*PW +: PW] = off[c]; end
    g3[0] = $urandom_range(1200); g3[1] = $urandom_range(600); g3[2] = 256 + $urandom_range(3000);
    gr = g3[0]; gg = g3[1]; gb = g3[2];
    for (int i = 0; i < w * h; i++) begin
      int x, y, c, col, v;
      x = i % w; y = i / w; img[i] = (i % 17 == 0) ? 10'd1023 : $urandom_range(1023);
      c = {y[0] ^ p[1], x[0] ^ p[0]};
      col = (c == 0) ? 0 : (c == 3) ? 2 : 1;
      v = bb ? img[i] : ((img[i] > off[c]) ? img[i] - off[c] : 0);
      if (!wbb) begin v = (v * g3[col] + 128) >> 8; if (v > 1023) v = 1023; end
      exp_px[i] = v;
    end
    for (int i = 0; i < w * h; i++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[i]; su <= (i == 0); sl <= (i % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (i == w * h / 2) begin                 // mid-frame changes must not take effect
        cfa <= ~p; blc_by <= ~bb; wb_by <= ~wbb;
      end
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("frame %0dx%0d: %0d pixels out", w, h, nout));
  endtask
