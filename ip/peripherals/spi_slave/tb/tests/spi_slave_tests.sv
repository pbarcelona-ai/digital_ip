// ***************
// Filename: spi_slave_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of spi_case, the test-case module of the
//   spi_slave testbench (spi_slave_tb.sv), moved out of it and `included
//   into that module, so they use its signals, parameters and models
//   directly. Tasks, in file order:
//     half
//     word   Master transfers one word
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic half(); repeat (HALF) @(posedge clk); endtask

  // master transfers one word; returns miso word
  task automatic word(input logic [NB-1:0] mo, output logic [NB-1:0] mi, input bit first);
    logic [NB-1:0] r; r = 0;
    for (int k = 0; k < NB; k++) begin
      if (!CPHA) begin
        if (k == 0) mosi = bit_of(mo, 0);
        half(); sclk = ~CPOL; #1;
        if (LSB) r[k] = miso; else r[NB-1-k] = miso;
        half(); sclk = CPOL; if (k < NB - 1) mosi = bit_of(mo, k + 1);
        else mosi = 1'b0;
      end else begin
        half(); sclk = ~CPOL; mosi = bit_of(mo, k);
        half(); sclk = CPOL; #1;
        if (LSB) r[k] = miso; else r[NB-1-k] = miso;
      end
    end
    mi = r;
  endtask

  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR NB=%0d cpol=%0d cpha=%0d lsb=%0d: %s", NB, CPOL, CPHA, LSB, m); end endtask
