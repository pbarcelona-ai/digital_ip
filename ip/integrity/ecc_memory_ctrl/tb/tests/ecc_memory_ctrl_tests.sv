// ***************
// Filename: ecc_memory_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the ecc_memory_ctrl_tb testbench
//   (ecc_memory_ctrl_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     wr     Register write over the bus
//     rdw    Read and wait for the response
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m_); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m_); end endtask

  task automatic wr(input int addr, input logic [DW-1:0] d, input logic [CW-1:0] mask);
    @(posedge clk); #1; while (!rdy) begin @(posedge clk); #1; end
    req = 1; we = 1; a = addr; wd = d; inj = mask; @(posedge clk); #1 req = 0; we = 0; inj = 0; m[addr] = d; corrupt[addr] = (mask != 0) && ($countones(mask) > 1);
  endtask

  // read and wait for the response; returns via globals
  task automatic rdw(input int addr);
    int n; n = 0;
    @(posedge clk); #1; while (!rdy) begin @(posedge clk); #1; end
    req = 1; we = 0; a = addr; @(posedge clk); #1 req = 0;
    while (!rv) begin @(posedge clk); #1; n++; end
    g_d = rd; g_sec = sec; g_ded = ded; g_lat = n;
  endtask
