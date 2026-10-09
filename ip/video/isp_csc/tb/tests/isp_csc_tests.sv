// ***************
// Filename: isp_csc_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_csc_tb testbench (isp_csc_tb.sv),
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

  task automatic frame(input int w, input int h, input bit bt709, input bit bypass);
    W = w;
    nout = 0;
    m709 = bt709;
    by = bypass;
    for (int n = 0; n < w * h; n++) begin
      if (n < 8) img[n] = {{8{n[2]}}, {8{n[1]}}, {8{n[0]}}};       // colour bar colours
      else img[n] = {8'($urandom_range(255)), 8'($urandom_range(255)), 8'($urandom_range(255))};
      exp_px[n] = bypass ? img[n] : model(img[n], bt709);
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
      if (n == w * h / 2) begin
        by <= ~bypass;
        m709 <= ~bt709;
      end
    end
    sv <= 0;
    repeat (20) @(posedge clk);
    check(nout == w * h, $sformatf("%0d pixels out of %0d", nout, w * h));
  endtask
