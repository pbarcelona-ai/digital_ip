// ***************
// Filename: axil_split_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_axil_split testbench
//   (axil_split_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     g_slave_report
// Date: 2026-10-08
// ***************
  task automatic g_slave_report(input int g);
    int e;
    if (g == 0) begin g_slave[0].u_chk.report(); e = g_slave[0].u_chk.errors + g_slave[0].u_chk.sva_errors; end
    else        begin g_slave[1].u_chk.report(); e = g_slave[1].u_chk.errors + g_slave[1].u_chk.sva_errors; end
    if (e != 0) begin errors++; $display("ERROR: protocol errors on slave port %0d", g); end
  endtask
