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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WORD_W < 2 || WORD_W > 32) begin : g_bad $error("i2s: WORD_W must be 2..32"); end
  localparam int PW = $clog2(2 * WORD_W);
  logic [7:0] hc;
  logic [PW-1:0] pos, nq;
  logic [WORD_W-1:0] txl, txr, rxl, rxr;
  logic synced;
  wire [7:0] half = (bclk_half_i == 0) ? 8'd1 : bclk_half_i;
  wire toggle = (hc >= half - 1'b1);
  wire fall = toggle & bclk_o;                // BCLK 1 -> 0 at this clock edge
  wire rise = toggle & ~bclk_o;               // BCLK 0 -> 1
  wire last_pos = (pos == PW'(2 * WORD_W - 1));
  wire [PW-1:0] wm1 = PW'(WORD_W - 1);
  logic bit_now;
  always_comb begin
    bit_now = 1'b0;
    for (int b = 0; b < WORD_W; b++) begin
      if (pos == PW'(b)) bit_now = txl[WORD_W - 1 - b];
      if (pos == PW'(WORD_W + b)) bit_now = txr[WORD_W - 1 - b];
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n || !en_i) begin
      hc <= '0;
      bclk_o <= 1'b0;
      lrck_o <= 1'b0;
      sd_o <= 1'b0;
      pos <= PW'(2 * WORD_W - 1);
      nq <= '0;
      txl <= '0;
      txr <= '0;
      rxl <= '0;
      rxr <= '0;
      rx_left_o <= '0;
      rx_right_o <= '0;
      rx_valid_o <= 1'b0;
      synced <= 1'b0;
      tx_ready_o <= 1'b0;
      underrun_o <= 1'b0;
    end else begin
      rx_valid_o <= 1'b0;
      tx_ready_o <= 1'b0;
      underrun_o <= 1'b0;
      if (toggle) begin
        hc <= '0;
        bclk_o <= ~bclk_o;
      end else hc <= hc + 1'b1;
      if (fall) begin
        sd_o   <= bit_now;
        lrck_o <= (pos >= wm1) && !last_pos;                 // right slot starts after bit WORD_W-1
        nq     <= pos;
        if (last_pos) begin
          pos <= '0;
          txl <= tx_valid_i ? tx_left_i : '0;
          txr <= tx_valid_i ? tx_right_i : '0;
          tx_ready_o <= tx_valid_i;
          underrun_o <= ~tx_valid_i;
        end else pos <= pos + 1'b1;
      end
      if (rise) begin                                         // sample the bit put on the line at the previous falling edge
        if (nq < PW'(WORD_W)) rxl <= {rxl[WORD_W-2:0], sd_i};
        else                  rxr <= {rxr[WORD_W-2:0], sd_i};
        if (nq == PW'(2 * WORD_W - 1)) begin
          synced <= 1'b1;
          if (synced) begin
            rx_left_o <= rxl;
            rx_right_o <= {rxr[WORD_W-2:0], sd_i};
            rx_valid_o <= 1'b1;
          end
        end
      end
    end
  end
endmodule
