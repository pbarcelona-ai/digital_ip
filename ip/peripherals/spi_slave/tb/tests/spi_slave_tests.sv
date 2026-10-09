// ***************
// Filename: spi_slave_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of spi_case, the test-case module of the
//   spi_slave testbench (spi_slave_tb.sv), moved out of it and `included
//   into that module, so they use its signals, parameters and models
//   directly. Tasks, in file order:
//     word   Master (spi_master_bfm) transfers one word
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  // the controller (spi_master_bfm) transfers one word; returns the MISO word
  task automatic word(input logic [NB-1:0] mo, output logic [NB-1:0] mi, input bit first);
    logic [31:0] r;
    spi.word(32'(mo), r);
    mi = r[NB-1:0];
  endtask

  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR NB=%0d cpol=%0d cpha=%0d lsb=%0d: %s", NB, CPOL, CPHA, LSB, m);
    end
  endtask
