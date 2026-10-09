// ***************
// Filename: pulse_generator_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the pulse_generator_tb testbench
//   (pulse_generator_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     meas   Measure over two consecutive start pulses
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // measure over two consecutive start pulses
  task automatic meas(output int period, output int width);
    int t0, t1, hi;
    hi = 0;
    @(posedge st);
    t0 = cyc;
    do begin
      @(posedge clk);
      #1 hi += p;
    end
    while (!st || cyc == t0);
    period = cyc - t0;
    width = hi;
  endtask
