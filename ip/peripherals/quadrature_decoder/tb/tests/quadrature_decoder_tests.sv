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
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Encoder step: forward sequence 00 -> 10 -> 11 -> 01 -> 00 (A leads)
  task automatic step(input bit fwd, input int hold);
    st = fwd ? (st + 1) % 4 : (st + 3) % 4;
    case (st) 0: {a,b} = 2'b00; 1: {a,b} = 2'b10; 2: {a,b} = 2'b11; 3: {a,b} = 2'b01; endcase
    repeat (hold) @(posedge aclk);
  endtask
