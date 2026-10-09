// ***************
// Filename: isp_gamma_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_gamma_tb testbench (isp_gamma_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     load
//     frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic load(input int curve);
    for (int a = 0; a < (1 << IW); a++) begin
      lut[a] = (curve == 1) ? OW'($rtoi(255.0 * ((a / 1023.0) ** (1.0 / 2.2)) + 0.5)) : OW'(255 - (a >> 2));
      @(posedge clk);
      we <= 1;
      wa <= a;
      wd <= lut[a];
    end
    @(posedge clk);
    we <= 0;
  endtask

  task automatic frame(input int w, input int h, input bit bypass);
    W = w;
    nout = 0;
    by = bypass;
    for (int n = 0; n < w * h; n++) begin
      img[n] = {IW'($urandom_range(1023)), IW'($urandom_range(1023)), IW'(n % 1024)};
      for (int k = 0; k < 3; k++) exp_px[n][k*OW +: OW] = bypass ? OW'(img[n][k*IW +: IW] >> 2) : lut[img[n][k*IW +: IW]];
    end
    for (int n = 0; n < w * h; n++) begin
      while ($urandom_range(99) < gap_pct) begin
        sv <= 0;
        @(posedge clk);
      end
      sd <= img[n];
      su <= (n == 0);
      sl <= (n % w == w - 1);
      sv <= 1;
      @(posedge clk);
      while (!sr) @(posedge clk);
      if (n == w * h / 2) by <= ~bypass;
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("%0d pixels out of %0d", nout, w * h));
  endtask
