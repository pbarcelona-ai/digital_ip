// ***************
// Filename: dds_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the dds_tb testbench (dds_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     tone
// Date: 2026-10-08
// ***************
  task automatic tone(input real f_mhz, input int n);
    tw = $rtoi(f_mhz / 100.0 * 4294967296.0); @(posedge clk); #1 en = 1; repeat (n) @(posedge clk); #1 en = 0; repeat (IT + 10) @(posedge clk);
  endtask
