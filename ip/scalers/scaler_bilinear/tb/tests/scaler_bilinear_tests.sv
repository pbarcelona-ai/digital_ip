// ***************
// Filename: scaler_bilinear_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_bilinear testbench
//   (scaler_bilinear_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     ip_configure  No IP-specific registers to program
// Date: 2026-10-08
// ***************
  // No IP-specific registers to program
  task automatic ip_configure();
  endtask
