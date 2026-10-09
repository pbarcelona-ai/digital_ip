// ***************
// Filename: nco_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the nco_tb testbench (nco_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask
