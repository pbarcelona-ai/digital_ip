// ***************
// Filename: axi4_lite_decoder_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the axi4_lite_decoder_tb testbench
//   (axi4_lite_decoder_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     t
// Date: 2026-10-08
// ***************
  task automatic t(input logic [31:0] x);
    logic [3:0] e; a = x; #1; e = model(x);
    if ({miss, sel} !== ((e[3]) ? {1'b1, 3'b000} : {1'b0, e[2:0]}) || multi) begin errors++; $display("ERROR addr %h: sel %b miss %b exp %b", x, sel, miss, e); end
  endtask
