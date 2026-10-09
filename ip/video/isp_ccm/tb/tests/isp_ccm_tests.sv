// ***************
// Filename: isp_ccm_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_ccm_tb testbench (isp_ccm_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic frame(input int w, input int h, input int kind, input bit bypass);
    int m [3][3]; int o [3];
    W = w; nout = 0; by = bypass;
    for (int i = 0; i < 3; i++) begin o[i] = 0; for (int j = 0; j < 3; j++) m[i][j] = (i == j) ? 1024 : 0; end
    if (kind == 1) begin                               // typical sensor CCM
      m[0][0] = 1720; m[0][1] = -520; m[0][2] = -176;
      m[1][0] = -300; m[1][1] = 1580; m[1][2] = -256;
      m[2][0] = -60;  m[2][1] = -610; m[2][2] = 1694;
    end
    if (kind == 2) begin                               // random, with offsets
      for (int i = 0; i < 3; i++) begin o[i] = $urandom_range(400) - 200; for (int j = 0; j < 3; j++) m[i][j] = $urandom_range(6000) - 3000; end
    end
    for (int i = 0; i < 3; i++) begin off[i*16 +: 16] = o[i]; for (int j = 0; j < 3; j++) coef[(3*i + j)*16 +: 16] = m[i][j]; end
    for (int n = 0; n < w * h; n++) begin
      img[n] = {PW'($urandom_range(1023)), PW'($urandom_range(1023)), PW'($urandom_range(1023))};
      for (int i = 0; i < 3; i++) begin
        longint s; int v;
        s = 512; for (int j = 0; j < 3; j++) s += longint'(m[i][j]) * longint'(img[n][j*PW +: PW]);
        v = int'(s >>> 10) + o[i];
        if (v < 0 || v > 1023) nclip++;
        if (v < 0) v = 0; if (v > 1023) v = 1023;
        exp_px[n][i*PW +: PW] = bypass ? img[n][i*PW +: PW] : PW'(v);
      end
    end
    for (int n = 0; n < w * h; n++) begin
      while ($urandom_range(99) < gap_pct) begin sv <= 0; @(posedge clk); end
      sd <= img[n]; su <= (n == 0); sl <= (n % w == w - 1); sv <= 1;
      @(posedge clk); while (!sr) @(posedge clk);
      if (n == w * h / 2) by <= ~bypass;
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("%0d pixels out of %0d", nout, w * h));
  endtask
