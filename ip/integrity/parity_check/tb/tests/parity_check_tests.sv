// ***************
// Filename: parity_check_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of pc_case, the test-case module of the
//   parity_check testbench (parity_check_tb.sv), moved out of it and
//   `included into that module, so they use its signals, parameters and
//   models directly. Tasks, in file order:
//     word
// Date: 2026-10-08
// ***************
  task automatic word(input logic [7:0] dd, input int flip);   // flip: -1 none, 0..7 data bit, 8 parity bit, 9 two data bits
    logic [7:0] x;
    logic pp;
    x = dd;
    pp = (^dd) ^ ODD;
    if (flip >= 0 && flip <= 7) x[flip] = ~x[flip];
    if (flip == 8) pp = ~pp;
    if (flip == 9) begin
      x[0] = ~x[0];
      x[1] = ~x[1];
    end
    @(posedge clk); // err_o pulses for this clock
    #1 v = 1;
    d = x;
    p = pp;
    @(posedge clk);
    #1 v = 0;
    if (e !== (flip >= 0 && flip != 9)) begin
      errors++;
      $display("ERROR odd=%0d word %h flip %0d err=%b", ODD, dd, flip, e);
    end
  endtask
