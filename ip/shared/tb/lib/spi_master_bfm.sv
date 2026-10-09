// ***************
// Filename: spi_master_bfm.sv
// Author: FPGA Cores 4 U
// Description: SPI controller (master) bus functional model, the partner
//   of an SPI target such as spi_slave (spi_bfm is the target model).
//   Timing is counted in cycles of clk: half_clks cycles per SCLK half
//   period. Line format: cpol, cpha, lsb_first, nbits (1..32).
//   select() / deselect() drive CS_N (deselect also returns SCLK to its
//   idle level); word() transfers one word in the current frame and
//   returns the word sampled on MISO; pulses() sends SCLK pulses without
//   completing a word.
// Date: 2026-10-09
`timescale 1ns/1ps

module spi_master_bfm (
  input  logic clk,                           // timing reference
  output logic sclk,
  output logic cs_n,
  output logic mosi,
  input  logic miso
);
  bit cpol = 0, cpha = 0, lsb_first = 0;
  int nbits = 8;
  int half_clks = 6;

  initial begin
    sclk = 0;
    cs_n = 1;
    mosi = 0;
  end

  function automatic logic bit_of(input logic [31:0] w, input int k);
    return lsb_first ? w[k] : w[nbits-1-k];
  endfunction

  task automatic half();
    repeat (half_clks) @(posedge clk);
  endtask

  // Idle levels for the current mode (call after changing cpol)
  task automatic idle();
    sclk = cpol;
    cs_n = 1;
    mosi = 0;
  endtask

  task automatic select(input logic mosi_level = 1'b0);
    cs_n = 0;
    mosi = mosi_level;
  endtask

  // n SCLK pulses without completing a word (protocol error injection)
  task automatic pulses(input int n);
    for (int k = 0; k < n; k++) begin
      half();
      sclk = ~cpol;
      half();
      sclk = cpol;
    end
  endtask

  task automatic deselect();
    cs_n = 1;
    sclk = cpol;
  endtask

  // One word: mo out on MOSI, mi in from MISO
  task automatic word(input logic [31:0] mo, output logic [31:0] mi);
    logic [31:0] r;
    r = 0;
    for (int k = 0; k < nbits; k++) begin
      if (!cpha) begin
        if (k == 0) mosi = bit_of(mo, 0);
        half();
        sclk = ~cpol;
        #1;
        if (lsb_first) r[k] = miso;
        else r[nbits-1-k] = miso;
        half();
        sclk = cpol;
        if (k < nbits - 1) mosi = bit_of(mo, k + 1);
        else mosi = 1'b0;
      end else begin
        half();
        sclk = ~cpol;
        mosi = bit_of(mo, k);
        half();
        sclk = cpol;
        #1;
        if (lsb_first) r[k] = miso;
        else r[nbits-1-k] = miso;
      end
    end
    mi = r;
  endtask
endmodule
