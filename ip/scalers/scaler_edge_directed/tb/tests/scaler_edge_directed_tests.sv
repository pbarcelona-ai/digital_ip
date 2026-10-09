// ***************
// Filename: scaler_edge_directed_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_edge_directed testbench
//   (scaler_edge_directed_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     ip_configure  Program and read back THRESH / EDGE_CTRL
// Date: 2026-10-08
// ***************
  // Program and read back THRESH / EDGE_CTRL
  task automatic ip_configure();
    axil_write(12'h040, thresh);
    axil_write(12'h044, edge_en);
    axil_check(12'h040, thresh);
    axil_check(12'h044, edge_en);
  endtask
