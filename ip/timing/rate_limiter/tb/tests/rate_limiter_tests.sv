// ***************
// Filename: rate_limiter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the rate_limiter_tb testbench
//   (rate_limiter_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     run
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run(input int n, output int got); // #1: after this edge's xf update
    int b;
    b = xf;
    repeat (n) @(posedge clk);
    #1 got = xf - b;
  endtask
