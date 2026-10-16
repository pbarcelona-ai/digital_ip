// ***************
// Filename: i2s.sv
// Author: FPGA Cores 4 U
// Description: I2S master transmitter and receiver (Philips I2S format).
//   Version 1.0.0. Generates BCLK and LRCK from the system clock (half
//   period bclk_half_i system clocks, so BCLK = f_clk / (2*bclk_half))
//   with LRCK low for the left slot and high for the right slot, data
//   changing on BCLK falling edges with the MSB one BCLK after the LRCK
//   edge, and samples sd_i on BCLK rising edges. Word width WORD_W (2..32
//   bits) equals the slot width, one frame is 2*WORD_W BCLKs (for a 48 kHz
//   frame at 100 MHz choose WORD_W=32 and bclk_half=... BCLK 3.072 MHz
//   needs bclk_half of about 16). Transmit takes a left/right sample pair
//   with tx_valid_i/tx_ready_o (tx_ready_o pulses when the pair is latched
//   at the frame boundary; if none is offered zeros are sent and
//   underrun_o pulses). Receive delivers each completed frame as
//   rx_left_o/rx_right_o with a one-clock rx_valid_o (the first partial
//   frame after enabling is discarded). sd_i must be synchronous to the
//   BCLK this block drives (device delay under half a BCLK). Clock - clk.
//   Reset - synchronous active low, BCLK/LRCK/SD low, idle. Latency - a
//   sample offered before a frame boundary is on the wire from the next
//   frame; receive result 1 clock after the last bit. Errors - bclk_half_i
//   = 0 is treated as 1; WORD_W outside 2..32 rejected at elaboration.
// Date: 2026-09-29

module i2s #(
  parameter int WORD_W = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              en_i,
  input  logic [7:0]        bclk_half_i,
  // transmit samples
  input  logic [WORD_W-1:0] tx_left_i,
  input  logic [WORD_W-1:0] tx_right_i,
  input  logic              tx_valid_i,
  output logic              tx_ready_o,
  // receive samples
  output logic [WORD_W-1:0] rx_left_o,
  output logic [WORD_W-1:0] rx_right_o,
  output logic              rx_valid_o,
  // serial pins
  output logic              bclk_o,
  output logic              lrck_o,
  output logic              sd_o,
  input  logic              sd_i,
  output logic              underrun_o
);
