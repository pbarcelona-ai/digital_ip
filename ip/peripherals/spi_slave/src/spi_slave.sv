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
//   elaboration.
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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WORD_BITS < 1 || WORD_BITS > 32) begin : g_bad $error("spi_slave: WORD_BITS must be 1..32"); end
  localparam int CW = $clog2(WORD_BITS + 1);
  logic sclk_s, cs_s, mosi_s, sclk_d, cs_d;
  bit_sync #(.STAGES(2), .RESET_VAL(1'b1)) u_cs   (.clk, .rst_n, .d_i(cs_n_i), .q_o(cs_s));
  bit_sync #(.STAGES(2), .RESET_VAL(CPOL)) u_sclk (.clk, .rst_n, .d_i(sclk_i), .q_o(sclk_s));
  bit_sync #(.STAGES(2)) u_mosi (.clk, .rst_n, .d_i(mosi_i), .q_o(mosi_s));
  always_ff @(posedge clk) begin
    if (!rst_n) begin sclk_d <= CPOL; cs_d <= 1'b1; end
    else begin sclk_d <= sclk_s; cs_d <= cs_s; end
  end
  wire cs_fall = cs_d & ~cs_s;
  wire cs_rise = ~cs_d & cs_s;
  wire lead    = (CPOL ? (sclk_d & ~sclk_s) : (~sclk_d & sclk_s)) & ~cs_s;   // first edge of each clock cycle
  wire trail   = (CPOL ? (~sclk_d & sclk_s) : (sclk_d & ~sclk_s)) & ~cs_s;
  wire sample  = CPHA ? trail : lead;
  wire shift   = CPHA ? lead : trail;

  logic [WORD_BITS-1:0] tx_word, rx_sr; logic [CW-1:0] scnt; logic miso_r;
  assign miso_o    = miso_r;
  assign miso_oe_o = ~cs_s;
  assign active_o  = ~cs_s;
  function automatic logic pick(input logic [WORD_BITS-1:0] wd, input logic [CW-1:0] idx);
    pick = LSB_FIRST ? wd[idx] : wd[WORD_BITS - 1 - idx];
  endfunction
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_word <= '0; rx_sr <= '0; scnt <= '0; miso_r <= 1'b0; rx_data_o <= '0; rx_valid_o <= 1'b0;
      tx_ready_o <= 1'b0; frame_end_o <= 1'b0; frame_err_o <= 1'b0; underrun_o <= 1'b0;
    end else begin
      rx_valid_o <= 1'b0; tx_ready_o <= 1'b0; frame_end_o <= 1'b0; frame_err_o <= 1'b0; underrun_o <= 1'b0;
      if (cs_fall) begin
        scnt <= '0;
        tx_word <= tx_valid_i ? tx_data_i : '0; tx_ready_o <= tx_valid_i; underrun_o <= ~tx_valid_i;
        miso_r <= pick(tx_valid_i ? tx_data_i : '0, '0);
      end else if (cs_rise) begin
        frame_end_o <= 1'b1; if (scnt != 0) frame_err_o <= 1'b1;
        scnt <= '0;
      end else begin
        if (sample) begin
          rx_sr <= LSB_FIRST ? {mosi_s, rx_sr[WORD_BITS-1:1]} : {rx_sr[WORD_BITS-2:0], mosi_s};
          if (scnt == WORD_BITS - 1) begin
            rx_data_o <= LSB_FIRST ? {mosi_s, rx_sr[WORD_BITS-1:1]} : {rx_sr[WORD_BITS-2:0], mosi_s};
            rx_valid_o <= 1'b1; scnt <= '0;
            tx_word <= tx_valid_i ? tx_data_i : '0; tx_ready_o <= tx_valid_i; underrun_o <= ~tx_valid_i;
          end else scnt <= scnt + 1'b1;
        end
        if (shift) miso_r <= pick(tx_word, scnt);
      end
    end
  end
endmodule
