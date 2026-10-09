// ***************
// Filename: quadrature_decoder_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the quadrature_decoder_tb testbench
//   (quadrature_decoder_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     step   Encoder step
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Encoder step (quad_bfm): forward 00 -> 10 -> 11 -> 01 -> 00 (A leads)
  task automatic step(input bit fwd, input int hold);
    enc.step(fwd, hold);
  endtask
