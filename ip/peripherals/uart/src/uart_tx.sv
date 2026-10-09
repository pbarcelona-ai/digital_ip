// ***************
// Filename: uart_tx.sv
// Author: FPGA Cores 4 U
// Description: UART transmitter. Pulls bytes from an AXI-Stream style
//   interface and shifts them out LSB first with a start bit, 5 to 8 data
//   bits, optional even or odd parity and one or two stop bits. Bit timing
//   comes from a 16x tick so each bit lasts 16 ticks. The tx line is
//   registered to avoid glitches. Version 1.0.0. Helper block of its IP; see
//   the top level description for clock, reset, latency and error behavior.
//   Errors - none reported here, out-of-range parameters stop elaboration or
//   are handled by the parent block.
// Date: 2026-09-29
module uart_tx (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tick16_i,
  input  logic       en_i,
  input  logic [3:0] data_bits_i,    // 5..8
  input  logic       parity_en_i,
  input  logic       parity_odd_i,
  input  logic       stop2_i,
  // Byte input stream
  input  logic [7:0] s_tdata,
  input  logic       s_tvalid,
  output logic       s_tready,
  // Serial output and status
  output logic       txd_o,
  output logic       busy_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  // State encoding
  localparam logic [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_DATA = 3'd2,
                         S_PAR  = 3'd3, S_STOP1 = 3'd4, S_STOP2 = 3'd5;
  logic [2:0] state;
  logic [3:0] tcnt;        // tick counter within a bit (0..15)
  logic [2:0] bitn;        // data bit index
  logic [7:0] sh;          // shift register
  logic       par;         // running parity of the data bits

  assign s_tready = (state == S_IDLE) & en_i;   // pop when starting a frame
  assign busy_o   = (state != S_IDLE);

  wire bit_end = tick16_i & (tcnt == 4'd15);    // last tick of the bit

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE;
      tcnt <= '0;
      bitn <= '0;
      sh <= '0;
      par <= 1'b0;
      txd_o <= 1'b1;
    end else begin
      if (tick16_i) tcnt <= tcnt + 4'd1;        // wraps naturally at 16
      case (state)
        S_IDLE: begin
          txd_o <= 1'b1;
          if (s_tvalid & en_i) begin            // load a new frame
            sh <= s_tdata;
            state <= S_START;
            tcnt <= '0;
            bitn <= '0;
            par <= 1'b0;
            txd_o <= 1'b0;
          end
        end
        S_START: begin
          txd_o <= 1'b0;
          if (bit_end) begin
            state <= S_DATA;
            txd_o <= sh[0];
          end
        end
        S_DATA: begin
          if (bit_end) begin
            par <= par ^ sh[0];
            sh  <= {1'b0, sh[7:1]};
            bitn <= bitn + 3'd1;
            if (bitn + 4'd1 == data_bits_i) begin       // last data bit sent
              if (parity_en_i) begin
                state <= S_PAR;
                txd_o <= par ^ sh[0] ^ parity_odd_i;
              end else begin
                state <= S_STOP1;
                txd_o <= 1'b1;
              end
            end else txd_o <= sh[1];                    // next data bit
          end
        end
        S_PAR: if (bit_end) begin
          state <= S_STOP1;
          txd_o <= 1'b1;
        end
        S_STOP1: begin
          if (bit_end) begin
            if (stop2_i) state <= S_STOP2;
            else         state <= S_IDLE;
          end
        end
        S_STOP2: if (bit_end) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
