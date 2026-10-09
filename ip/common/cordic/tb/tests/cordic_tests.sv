// ***************
// Filename: cordic_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the cordic_tb testbench (cordic_tb.sv), moved
//   out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     drive
// Date: 2026-10-08
// ***************
  task automatic drive(input int x, input int y, input int z);
    @(posedge clk);
    #1 v_i = 1;
    xi = x;
    yi = y;
    zi = z;
  endtask
