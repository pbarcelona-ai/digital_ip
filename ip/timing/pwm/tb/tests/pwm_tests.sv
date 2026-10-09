// ***************
// Filename: pwm_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the pwm_tb testbench (pwm_tb.sv), moved out of
//   it and `included into that module, so they use its signals, parameters
//   and models directly. Tasks, in file order:
//     check    Counts an error and prints the message when the condition is
//              false
//     measure  Measure high count of channel ch and period length over one
//              full period
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Measure high count of channel ch and period length over one full period
  task automatic measure(input int ch);
    @(posedge pp);
    #1;
    hi_cnt = 0;
    per_cnt = 0;
    do begin
      @(posedge aclk);
      #1;
      per_cnt++;
      hi_cnt += pwm[ch];
    end
    while (!pp);
  endtask
