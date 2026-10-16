// ***************
// Filename: spi_slave.sv
// Author: FPGA Cores 4 U
// Description: SPI slave (all four modes, 1..32 bit words, MSB or LSB first).
//   Version 1.0.0. sclk, cs_n and mosi are asynchronous inputs, each passed
//   through a 2-flop synchronizer and edge-detected in the system clock
//   domain, so no SPI signal is used as a clock. Requirement - sclk period at
//   least 6 system clocks (f_sclk <= f_clk/6, e.g. 16 MHz sclk at 100 MHz)
//   and cs_n low at least 4 system clocks before the first sclk edge.
//   Transmit - the word offered on tx_data_i (tx_valid_i high) is loaded when
//   cs_n falls and after every completed word, tx_ready_o pulses when it is
//   taken; if none is offered zeros are sent and underrun_o pulses. Receive -
//   rx_valid_o pulses for one clock with rx_data_o after every full word.
//   Frame errors - cs_n rising in the middle of a word discards it and pulses
//   frame_err_o. miso_oe_o is high while cs_n is low (connect to a tri-state
//   buffer at the top level; no vendor primitive here). Reset - synchronous
//   active low, idle. Latency - rx_valid_o about 3 system clocks after the
//   sampling sclk edge. Errors - WORD_BITS outside 1..32 rejected at
//   elaboration. Clock - the clock of the parent block, all signals are
//   synchronous to it.
//   synchronous to it.
// Date: 2026-09-29

module spi_slave #(
  parameter int WORD_BITS = 8,
  parameter bit CPOL      = 1'b0,
  parameter bit CPHA      = 1'b0,
  parameter bit LSB_FIRST = 1'b0
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // SPI pins
  input  logic                 sclk_i,
  input  logic                 cs_n_i,
  input  logic                 mosi_i,
  output logic                 miso_o,
  output logic                 miso_oe_o,
  // Transmit word
  input  logic [WORD_BITS-1:0] tx_data_i,
  input  logic                 tx_valid_i,
  output logic                 tx_ready_o,
  // Receive word
  output logic [WORD_BITS-1:0] rx_data_o,
  output logic                 rx_valid_o,
  // Status
  output logic                 active_o,       // cs_n low (synchronized)
  output logic                 frame_end_o,    // cs_n rose
  output logic                 frame_err_o,
  output logic                 underrun_o
);
