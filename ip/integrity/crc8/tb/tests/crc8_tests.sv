// ***************
// Filename: crc8_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the crc8_tb testbench (crc8_tb.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     feed
// Date: 2026-10-08
// ***************
  task automatic feed();
    int n, idx; n = msg.size();
    @(posedge clk); #1 init = 1; @(posedge clk); #1 init = 0;
    for (int i = 0; i < n; i++) begin
      @(posedge clk); #1 v8 = 1; d8 = msg[i];
      if ($urandom_range(0, 5) == 0) begin @(posedge clk); #1 v8 = 0; end       // idle gap
    end
    @(posedge clk); #1 v8 = 0;
    idx = 0;
    while (idx < n) begin
      logic [31:0] w32; logic [3:0] kp; w32 = 0; kp = 0;
      for (int b = 0; b < 4; b++) if (idx + b < n) begin w32[b*8 +: 8] = msg[idx + b]; kp[b] = 1; end
      @(posedge clk); #1 v32 = 1; d32 = w32; k32 = kp; idx += 4;
    end
    @(posedge clk); #1 v32 = 0; @(posedge clk); #1;
  endtask
