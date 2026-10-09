// ***************
// Filename: frequency_counter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the frequency_counter_tb testbench
//   (frequency_counter_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     check         Counts an error and prints the message when the condition
//                   is false
//     expect_edges
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic expect_edges(input real f_mhz);
    int e; e = int'(f_mhz * 100.0);               // edges in 100 us
    half = 500.0 / f_mhz; #2000; @(posedge v); @(posedge v); #1;
    check(cnt >= e - 1 && cnt <= e + 1 && !ov, $sformatf("%f MHz: count %0d exp %0d", f_mhz, cnt, e));
  endtask
