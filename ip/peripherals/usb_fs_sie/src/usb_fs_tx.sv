// ***************
// Filename: usb_fs_tx.sv
// Author: FPGA Cores 4 U
// Description: USB 1.1 full-speed transmitter. Takes a whole packet from a
//   byte stream (first byte low nibble is the PID, the complement nibble is
//   generated here) and sends SYNC, PID, payload, CRC and EOP with NRZI
//   encoding and bit stuffing. CRC5 is appended for token packets (PID group
//   01 and PING; the 11 bit address and endpoint come from two payload bytes,
//   only 3 bits of the second are used), CRC16 for data packets (PID group
//   11), handshakes carry no payload. Bit timing uses a fractional
//   accumulator so any clock rate works; at 100 MHz individual bit edges have
//   one clock of jitter, use 48 or 60 MHz for compliant electrical timing.
//   Version 1.0.0. Clock - the clock of the parent block, all signals are
//   synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module usb_fs_tx #(
  parameter int CLK_HZ = 100_000_000
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       enable_i,
  input  logic       bus_busy_i,     // do not start while receiving
  // Packet bytes (a complete packet must be available)
  input  logic [7:0] s_data,
  input  logic       s_valid,
  input  logic       s_last,
  input  logic       pkt_avail_i,
  output logic       s_ready,        // pop strobe
  // Line drivers
  output logic       dp_o,
  output logic       dm_o,
  output logic       oe_o,
  // Status
  output logic       busy_o,
  output logic       pkt_done_o      // one clock per packet sent
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam logic [63:0] P64 = (64'(CLK_HZ) * 64'd256 + 64'd6_000_000) / 64'd12_000_000;
  localparam logic [23:0] P   = P64[23:0];

  typedef enum logic [3:0] {
    T_IDLE, T_SYNC, T_PID, T_PAY, T_CRC, T_END, T_EOP1, T_EOP2, T_EOP3, T_DRAIN
  } tstate_t;
  tstate_t     state;

  logic [23:0] acc;                 // bit timer accumulator (8.8 clocks)
  logic        tick;                // one strobe per bit time
  logic [7:0]  sh;                  // current byte, LSB first
  logic [3:0]  bl;                  // bits left in the byte
  logic [2:0]  ones;                // consecutive ones for stuffing
  logic        j;                   // line currently J (NRZI state)
  logic [15:0] crc16;
  logic [4:0]  crc5;
  logic [15:0] crc_sh;              // CRC bits to send
  logic [4:0]  crc_left;
  logic        last_seen;           // stream tlast has been popped
  logic        is_data, is_tok;
  logic        tok_b1;              // second token byte (only 3 bits)
  logic [7:0]  pid_full;

  wire [23:0] acc_lin = acc + 24'd256;
  assign busy_o = (state != T_IDLE);

  // Pop strobe: PID at start, payload bytes on byte boundaries, drain
  logic pop_pay;
  always_comb begin
    s_ready = 1'b0;
    case (state)
      T_IDLE:  s_ready = enable_i & pkt_avail_i & s_valid & ~bus_busy_i;
      T_DRAIN: s_ready = s_valid;
      default: s_ready = pop_pay;
    endcase
  end

  // Bit source for the current phase
  wire       stuffing = (ones == 3'd6) && (state == T_PID || state == T_PAY ||
                                           state == T_CRC);
  wire       src_bit  = (state == T_SYNC) ? sh[0] :
                        (state == T_CRC)  ? crc_sh[0] : sh[0];
  wire       b_send   = stuffing ? 1'b0 : src_bit;      // bit put on the wire
  wire       j_next   = b_send ? j : ~j;                // NRZI: 0 toggles
  // CRC updates (only for payload bits)
  wire       c16_fb   = crc16[0] ^ src_bit;
  wire       c5_fb    = crc5[0]  ^ src_bit;
  wire [15:0] crc16_n = {1'b0, crc16[15:1]} ^ (c16_fb ? 16'hA001 : 16'h0);
  wire [4:0]  crc5_n  = {1'b0, crc5[4:1]}   ^ (c5_fb  ? 5'h14   : 5'h00);
  wire       byte_end = (bl == 4'd1) && !stuffing;

  // Next payload byte handling at a byte boundary
  always_comb begin
    pop_pay = 1'b0;
    if (tick && state == T_PAY && byte_end && !last_seen && !(is_tok && tok_b1))
      pop_pay = s_valid;
    if (tick && state == T_PID && byte_end && !last_seen && (is_data || is_tok))
      pop_pay = s_valid;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= T_IDLE; acc <= '0; tick <= 1'b0; sh <= '0; bl <= '0; ones <= '0;
      j <= 1'b1; crc16 <= 16'hFFFF; crc5 <= 5'h1F; crc_sh <= '0; crc_left <= '0;
      last_seen <= 1'b0; is_data <= 1'b0; is_tok <= 1'b0; tok_b1 <= 1'b0;
      pid_full <= '0; dp_o <= 1'b1; dm_o <= 1'b0; oe_o <= 1'b0; pkt_done_o <= 1'b0;
    end else begin
      pkt_done_o <= 1'b0;
      tick <= 1'b0;
      // Bit timer runs only while sending
      if (state != T_IDLE && state != T_DRAIN) begin
        if (acc_lin >= P) begin acc <= acc_lin - P; tick <= 1'b1; end
        else              acc <= acc_lin;
      end

      case (state)
        T_IDLE: if (s_ready) begin                     // start a packet
          pid_full  <= {~s_data[3:0], s_data[3:0]};
          is_data   <= (s_data[1:0] == 2'b11);
          is_tok    <= (s_data[1:0] == 2'b01) || (s_data[3:0] == 4'b0100);
          last_seen <= s_last;
          sh <= 8'h80; bl <= 4'd8; ones <= '0; j <= 1'b1;
          crc16 <= 16'hFFFF; crc5 <= 5'h1F; tok_b1 <= 1'b0;
          acc <= P - 24'd256;                          // first tick next clock
          oe_o <= 1'b1; dp_o <= 1'b1; dm_o <= 1'b0;    // start from J
          state <= T_SYNC;
        end

        T_SYNC, T_PID, T_PAY, T_CRC: if (tick) begin
          // Drive the next line state
          j <= j_next; dp_o <= j_next; dm_o <= ~j_next;
          if (stuffing) ones <= '0;
          else begin
            ones <= b_send ? ones + 3'd1 : 3'd0;
            sh   <= {1'b0, sh[7:1]};
            bl   <= bl - 4'd1;
            if (state == T_PAY) begin crc16 <= crc16_n; crc5 <= crc5_n; end
            if (state == T_CRC) begin
              crc_sh <= {1'b0, crc_sh[15:1]}; crc_left <= crc_left - 5'd1;
              if (crc_left == 5'd1) state <= T_END;
            end
            if (byte_end) begin
              case (state)
                T_SYNC: begin
                  sh <= pid_full; bl <= 4'd8; state <= T_PID;
                end
                T_PID: begin
                  if (is_data || is_tok) begin
                    if (last_seen) begin                     // no payload
                      if (is_data) begin
                        crc_sh <= ~16'hFFFF; crc_left <= 5'd16; state <= T_CRC;
                      end else state <= T_END;
                    end else begin
                      sh <= s_data; last_seen <= s_last; bl <= 4'd8; state <= T_PAY;
                    end
                  end else state <= T_END;                   // handshake
                end
                T_PAY: begin
                  if (is_tok && tok_b1) begin                // 11th bit sent
                    crc_sh <= {11'd0, ~crc5_n}; crc_left <= 5'd5; state <= T_CRC;
                  end else if (last_seen) begin
                    if (is_data) begin
                      crc_sh <= ~crc16_n; crc_left <= 5'd16; state <= T_CRC;
                    end else state <= T_END;                 // short token
                  end else begin
                    sh <= s_data; last_seen <= s_last;
                    bl <= (is_tok) ? 4'd3 : 4'd8;
                    if (is_tok) tok_b1 <= 1'b1;
                  end
                end
                default: ;
              endcase
            end
          end
        end

        // After the last bit: insert a stuff bit if needed, then EOP
        T_END: if (tick) begin
          if (ones == 3'd6) begin
            j <= ~j; dp_o <= ~j; dm_o <= j; ones <= '0;   // stuff a zero
          end else begin
            dp_o <= 1'b0; dm_o <= 1'b0; state <= T_EOP1;  // SE0
          end
        end
        T_EOP1: if (tick) begin dp_o <= 1'b0; dm_o <= 1'b0; state <= T_EOP2; end
        T_EOP2: if (tick) begin dp_o <= 1'b1; dm_o <= 1'b0; j <= 1'b1; state <= T_EOP3; end
        T_EOP3: if (tick) begin
          oe_o <= 1'b0; pkt_done_o <= 1'b1;
          state <= tstate_t'(last_seen ? T_IDLE : T_DRAIN);
        end
        T_DRAIN: if (s_valid) begin                        // discard extra bytes
          if (s_last) state <= T_IDLE;
        end
        default: state <= T_IDLE;
      endcase
    end
  end
endmodule
