// ***************
// Filename: mulq_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_mulq testbench (tb_mulq.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     drive  Two-deep expected/input history to align with the 2-cycle latency
// Date: 2026-10-08
// ***************
  // Two-deep expected/input history to align with the 2-cycle latency.
  task automatic drive(input logic signed [31:0] x, input logic signed [31:0] y);
    begin
      @(posedge clk);
      a <= x; b <= y;
    end
  endtask
