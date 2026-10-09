// ***************
// Filename: clock_enable_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the clock_enable_tb testbench
//   (clock_enable_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check    Counts an error and prints the message when the condition is
//              false
//     spacing
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic spacing(input int expect_div);
    int a, b;
    @(posedge ce);
    a = cyc;
    @(posedge ce);
    b = cyc;
    @(posedge ce);
    check(b - a == expect_div && cyc - b == expect_div, $sformatf("div %0d spacing %0d/%0d", expect_div, b - a, cyc - b));
  endtask
