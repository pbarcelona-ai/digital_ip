// ***************
// Filename: i2s_bfm.sv
// Author: FPGA Cores 4 U
// Description: I2S bus functional model: an audio codec on an I2S link
//   whose bit clock (bclk) and word select (lrck) come from the DUT
//   (the DUT is the clock master). Standard I2S format: lrck low = left,
//   W-bit words MSB first, data one bclk after the lrck edge, driven on the
//   falling and sampled on the rising bclk edge.
//   Receiver (DAC side): decodes the DUT's serial output sd_i into
//   rx_left_q / rx_right_q (rx_frames, rx_done after each right word).
//   Transmitter (ADC side): sends tx_left_q / tx_right_q pairs on sd_o,
//   a new pair at every left word; the pairs actually sent are appended to
//   sent_left_q / sent_right_q (zeros when the queue is empty).
// Date: 2026-10-09
`timescale 1ns/1ps

module i2s_bfm #(
  parameter int W = 16                        // bits per channel word
) (
  input  logic bclk,
  input  logic lrck,
  input  logic sd_i,                          // DUT serial data out -> codec DAC
  output logic sd_o                           // codec ADC -> DUT serial data in
);
  // receiver
  logic [W-1:0] rx_left_q[$], rx_right_q[$];
  int           rx_frames = 0;
  event         rx_done;
  logic [W-1:0] rsr = '0;
  int           rcnt = 0;
  logic         rlr_q = 1'b1;
  // transmitter
  logic [W-1:0] tx_left_q[$], tx_right_q[$];
  logic [W-1:0] sent_left_q[$], sent_right_q[$];
  logic [W-1:0] tword = '0, tright = '0;
  int           tidx = W;
  logic         tlr_q = 1'b1;
  initial sd_o = 1'b0;

  // receive: the sample taken on the rising edge after an lrck change is the LSB of the previous word
  always @(posedge bclk) begin
    rsr = {rsr[W-2:0], sd_i};
    rcnt++;
    if (lrck != rlr_q) begin
      if (rcnt >= W) begin
        if (rlr_q == 1'b0) rx_left_q.push_back(rsr);
        else begin
          rx_right_q.push_back(rsr);
          rx_frames++;
          -> rx_done;
        end
      end
      rcnt = 0;
      rlr_q = lrck;
    end
  end

  // transmit: the bit driven at the falling edge of an lrck change is the LSB of the previous word,
  // the next word's MSB follows one bclk later
  always @(negedge bclk) begin
    sd_o <= (tidx < W) ? tword[W-1-tidx] : 1'b0;
    tidx++;
    if (lrck != tlr_q) begin
      if (lrck == 1'b0) begin                 // left word starts: take the next pair
        logic [W-1:0] l;
        l = tx_left_q.size() ? tx_left_q.pop_front() : '0;
        tright = tx_right_q.size() ? tx_right_q.pop_front() : '0;
        sent_left_q.push_back(l);
        sent_right_q.push_back(tright);
        tword = l;
      end else tword = tright;
      tidx = 0;
      tlr_q = lrck;
    end
  end
endmodule
