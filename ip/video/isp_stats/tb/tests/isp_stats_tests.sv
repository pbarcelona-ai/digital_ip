// ***************
// Filename: isp_stats_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the isp_stats_tb testbench (isp_stats_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     frame  Drive npix accepted pixels
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Drive npix accepted pixels; tuser on the first one
  task automatic frame(input int npix);
    int n;
    n = 0;
    while (n < npix) begin
      v <= ($urandom_range(3) != 0);
      r <= ($urandom_range(3) != 0);
      u <= (n == 0);
      d <= {8'($urandom_range(255)), 8'($urandom_range(255)), 8'($urandom_range(255))};
      @(posedge clk);
      if (v && r) n++;
    end
    v <= 0;
    u <= 0;
  endtask
