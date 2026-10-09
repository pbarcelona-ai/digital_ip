// ***************
// Filename: spi_bfm.sv
// Author: FPGA Cores 4 U
// Description: SPI bus functional model: a behavioral SPI target (slave). Captures
//   MOSI into rx_word and returns tx_word on MISO for every SPI mode
//   (cpol / cpha), MSB- or LSB-first, 1..32 bit words.
// Date: 2026-10-09
`timescale 1ns/1ps

// Behavioral SPI slave. Captures MOSI into rx_word and returns tx_word on MISO.
module spi_bfm (
  input  logic sclk, input logic cs_n, input logic mosi, output logic miso,
  input  logic cpol, input logic cpha, input logic lsb_first,
  input  int   nbits,
  input  logic [31:0] tx_word,
  output logic [31:0] rx_word,
  output int   words_seen
);
  int idx;              // bit counter
  int nedge;            // edge counter within the word
  logic [31:0] rx_sr;
  logic miso_q, miso_oe;  // MISO data and output enable (tri-stated while deselected)
  assign miso = miso_oe ? miso_q : 1'bz;
  initial begin
    miso_oe = 0;
    miso_q = 0;
    words_seen = 0;
    rx_word = 0;
  end
  // Chip select falling: prepare first bit (CPHA=0 drives before first edge)
  always @(negedge cs_n) begin
    idx = 0;
    nedge = 0;
    rx_sr = 0;
    miso_oe = !cpha;
    miso_q = tx_word[lsb_first ? 0 : nbits-1];
  end
  always @(posedge cs_n) miso_oe = 0;
  // Every SCLK edge while selected
  always @(sclk) if (!cs_n) begin
    logic lead;
    lead = (sclk != cpol);                        // leading (active) edge
    if (lead == !cpha) begin                     // sample edge
      rx_sr[lsb_first ? idx : nbits-1-idx] = mosi;
      if (idx == nbits-1) begin
        rx_word = rx_sr;
        words_seen++;
      end
      idx++;
    end else begin                                // shift edge
      if (idx < nbits) begin
        miso_oe = 1;
        miso_q = tx_word[lsb_first ? idx : nbits-1-idx];
      end
    end
    if (idx == nbits && (lead != !cpha)) idx = 0;  // ready for a next word
  end
endmodule
