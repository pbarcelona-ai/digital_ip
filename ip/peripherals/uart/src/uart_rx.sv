// ***************
// Filename: uart_rx.sv
// Author: FPGA Cores 4 U
// Description: UART receiver. Two flop synchronizer, start bit qualification
//   at mid bit, then sampling every 16 ticks in the middle of each bit.
//   Supports 5 to 8 data bits, optional parity and stop bit check. Produces a
//   one clock word strobe with parity and framing error flags. Break and
//   noise on the start bit are rejected. Version 1.0.0. Helper block of its
//   IP; see the top level description for clock, reset, latency and error
//   behavior. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module uart_rx (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tick16_i,
  input  logic       en_i,
  input  logic [3:0] data_bits_i,
  input  logic       parity_en_i,
  input  logic       parity_odd_i,
  input  logic       rxd_i,          // asynchronous serial input
  output logic [7:0] data_o,
  output logic       valid_o,        // one clock strobe per received word
  output logic       frame_err_o,    // valid with word: stop bit low
  output logic       parity_err_o,   // valid with word: parity mismatch
  output logic       busy_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  localparam logic [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_DATA = 3'd2,
                         S_PAR = 3'd3, S_STOP = 3'd4;
  (* async_reg = "true" *) logic [1:0] sync_q;
  logic       rxs;                    // synchronized rx
  logic [2:0] state;
  logic [3:0] tcnt;
  logic [2:0] bitn;
  logic [7:0] word;
  logic       par;
  logic       perr;
  logic       armed;              // line seen idle (high) since last frame

  assign busy_o = (state != S_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sync_q <= 2'b11; rxs <= 1'b1;
    end else begin
      sync_q <= {sync_q[0], rxd_i};
      rxs    <= sync_q[1];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; tcnt <= '0; bitn <= '0; word <= '0; par <= 1'b0;
      armed <= 1'b0; perr <= 1'b0; valid_o <= 1'b0; frame_err_o <= 1'b0; parity_err_o <= 1'b0;
      data_o <= '0;
    end else begin
      valid_o <= 1'b0;
      case (state)
        S_IDLE: begin
          tcnt <= '0;
          if (rxs) armed <= 1'b1;                        // line is idle
          else if (armed & en_i) begin                   // falling edge
            state <= S_START; armed <= 1'b0;             // (break holds off)
          end
        end
        S_START: if (tick16_i) begin
          if (tcnt == 4'd7) begin                        // middle of start
            tcnt <= '0;
            if (rxs) state <= S_IDLE;                    // glitch: reject
            else begin state <= S_DATA; bitn <= '0; par <= 1'b0; word <= '0; end
          end else tcnt <= tcnt + 4'd1;
        end
        S_DATA: if (tick16_i) begin
          tcnt <= tcnt + 4'd1;
          if (tcnt == 4'd15) begin                       // mid bit sample
            word[bitn] <= rxs;
            par        <= par ^ rxs;
            bitn       <= bitn + 3'd1;
            if (bitn + 4'd1 == data_bits_i)
              state <= parity_en_i ? S_PAR : S_STOP;
          end
        end
        S_PAR: if (tick16_i) begin
          tcnt <= tcnt + 4'd1;
          if (tcnt == 4'd15) begin
            perr  <= ((par ^ parity_odd_i) != rxs);
            state <= S_STOP;
          end
        end
        S_STOP: if (tick16_i) begin
          tcnt <= tcnt + 4'd1;
          if (tcnt == 4'd15) begin                       // mid stop bit
            data_o       <= word;
            valid_o      <= 1'b1;
            frame_err_o  <= ~rxs;
            parity_err_o <= perr & parity_en_i;
            perr         <= 1'b0;
            state        <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
