// ***************
// Filename: checksum_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of cs_case, the test-case module of the checksum
//   testbench (checksum_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     run
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic run();
    @(posedge clk); #1 init = 1; @(posedge clk); #1 init = 0;
    for (int i = 0; i < msg.size(); i++) begin @(posedge clk); #1 v = 1; b = msg[i]; end
    @(posedge clk); #1 v = 0; @(posedge clk); #1;
  endtask

  task automatic check(input bit c_, input string m); if (!c_) begin errors++; $display("ERROR mode %0d: %s", MODE, m); end endtask
