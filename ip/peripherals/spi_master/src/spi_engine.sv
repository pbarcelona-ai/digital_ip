// ***************
// Filename: spi_engine.sv
// Author: FPGA Cores 4 U
// Description: SPI master shift engine. Supports all four clock modes
//   (cpol/cpha), MSB or LSB first, word length 1 to DATA_W bits and a
//   programmable SCLK half period. A word is loaded, chip select is asserted,
//   the word is clocked out while MISO is captured, and chip select is kept
//   low for back-to-back words or released after the last word of a burst.
//   MISO is double registered. Version 1.0.0. Helper block of its IP; see the
//   top level description for clock, reset, latency and error behavior. Clock
//   - the clock of the parent block, all signals are synchronous to it. Reset
//   - synchronous, driven by the parent block. Latency - as documented in the
//   parent block, fixed and independent of data. Errors - none reported here,
//   out-of-range parameters stop elaboration or are handled by the parent
//   block.
//   - synchronous, driven by the parent block. Latency - as documented in the
//   parent block, fixed and independent of data. Errors - none reported here,
//   out-of-range parameters stop elaboration or are handled by the parent
//   block.
// Date: 2026-09-29
module spi_engine #(
  parameter int DATA_W = 32,
  parameter int NUM_CS = 4
) (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      enable_i,
  input  logic                      cpol_i,
  input  logic                      cpha_i,
  input  logic                      lsb_first_i,
  input  logic [5:0]                word_len_i,   // bits per word, 1..DATA_W
  input  logic [15:0]               div_i,        // half period = div_i+1 clocks
  input  logic [$clog2(NUM_CS)-1:0] cs_sel_i,
  // Word to transmit
  input  logic [DATA_W-1:0]         tx_data,
  input  logic                      tx_last,      // release CS after this word
  input  logic                      tx_valid,
  output logic                      tx_ready,
  // Received word
  output logic [DATA_W-1:0]         rx_data,
  output logic                      rx_last,
  output logic                      rx_valid,     // one clock strobe
  // Pins
  output logic                      sclk_o,
  output logic                      mosi_o,
  input  logic                      miso_i,
  output logic [NUM_CS-1:0]         cs_n_o,
  output logic                      busy_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  typedef enum logic [2:0] {
    S_IDLE, S_CS_SETUP, S_SHIFT, S_CS_HOLD, S_DONE
  } state_t;
  state_t state;

  (* async_reg = "true" *) logic [1:0] miso_sq;  // 2FF synchronizer
  logic [DATA_W-1:0] tx_word, rx_word;
  logic              last_q;
  logic [15:0]       tmr;
  logic [6:0]        edge_cnt;     // half-period edge index 0 .. 2*len-1
  localparam int IDX_W = $clog2(DATA_W);          // bit index width
  localparam logic [IDX_W-1:0] ONE = 1;
  logic [IDX_W-1:0]  tx_idx, rx_idx;
  logic              cs_active;    // chip select currently asserted

  wire tmr_zero = (tmr == 16'd0);
  wire [6:0] last_edge = {word_len_i, 1'b0} - 7'd1;   // 2*len - 1
  wire [IDX_W-1:0] tx_idx_nxt = lsb_first_i ? tx_idx + ONE : tx_idx - ONE;
  wire [5:0] wl_m1 = word_len_i - 6'd1;
  wire [IDX_W-1:0] first_idx = lsb_first_i ? '0 : wl_m1[IDX_W-1:0];

  assign busy_o   = (state != S_IDLE);
  assign tx_ready = (state == S_IDLE) & enable_i;

  // Chip select decode: one glitch-free registered assignment per line
  always_ff @(posedge clk) begin
    if (!rst_n) cs_n_o <= '1;
    else begin
      for (int i = 0; i < NUM_CS; i++)
        cs_n_o[i] <= ~(cs_active && (cs_sel_i == i[$clog2(NUM_CS)-1:0]));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) miso_sq <= '0;
    else        miso_sq <= {miso_sq[0], miso_i};
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; tmr <= '0; edge_cnt <= '0; tx_idx <= '0; rx_idx <= '0;
      tx_word <= '0; rx_word <= '0; last_q <= 1'b0; cs_active <= 1'b0;
      sclk_o <= 1'b0; mosi_o <= 1'b0; rx_data <= '0; rx_last <= 1'b0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      if (tmr != 16'd0) tmr <= tmr - 16'd1;
      case (state)
        S_IDLE: begin
          sclk_o <= cpol_i;
          if (tx_valid & enable_i) begin              // load word
            tx_word <= tx_data; last_q <= tx_last;
            rx_word <= '0; edge_cnt <= '0;
            tx_idx <= first_idx; rx_idx <= first_idx;
            state <= S_CS_SETUP; tmr <= div_i;
            cs_active <= 1'b1;
            // CPHA=0: first bit must be valid before the first edge
            if (!cpha_i) mosi_o <= tx_data[first_idx];
          end else if (!cs_active) mosi_o <= 1'b0;
        end
        S_CS_SETUP: if (tmr_zero) begin state <= S_SHIFT; tmr <= div_i; end
        S_SHIFT: if (tmr_zero) begin
          tmr    <= div_i;
          sclk_o <= ~sclk_o;                          // toggle every half period
          edge_cnt <= edge_cnt + 7'd1;
          // Sample edge: even edges for CPHA=0, odd edges for CPHA=1
          if (edge_cnt[0] == cpha_i) begin
            rx_word[rx_idx] <= miso_sq[1];
            rx_idx <= lsb_first_i ? rx_idx + ONE : rx_idx - ONE;
          end else begin
            // Shift edge: present the next bit (CPHA=1 first bit at edge 0)
            if (cpha_i && edge_cnt == 7'd0) begin
              mosi_o <= tx_word[tx_idx];
            end else if (edge_cnt != last_edge) begin
              mosi_o <= tx_word[tx_idx_nxt];          // next bit of the word
              tx_idx <= tx_idx_nxt;
            end
          end
          if (edge_cnt == last_edge) begin
            state <= S_CS_HOLD; tmr <= div_i;
          end
        end
        S_CS_HOLD: if (tmr_zero) state <= S_DONE;
        S_DONE: begin
          rx_data <= rx_word; rx_last <= last_q; rx_valid <= 1'b1;
          if (last_q) cs_active <= 1'b0;             // end of burst
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
