// ***************
// Filename: usb_fs_rx.sv
// Author: FPGA Cores 4 U
// Description: USB 1.1 full-speed receiver. Two flop synchronizers, J/K/SE0
//   decode, and a fractional-N clock recovery loop that restarts its bit
//   phase on every line transition and samples mid-bit, so it works at any
//   system clock above about 4x the 12 Mbit/s bit rate. Then SYNC detection,
//   NRZI decode, bit unstuffing, PID check, CRC5 (tokens) and CRC16 (data)
//   checking and EOP detection. Packets leave as a byte stream - PID low
//   nibble first, then payload with the CRC16 removed - with tlast and a
//   tuser error flag on the final byte. Also flags a bus reset (SE0 longer
//   than 2.5 us). Version 1.0.0. Clock - the clock of the parent block, all
//   signals are synchronous to it. Reset - synchronous, driven by the parent
//   block. Latency - as documented in the parent block, fixed and independent
//   of data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module usb_fs_rx #(
  parameter int CLK_HZ = 100_000_000
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       enable_i,       // 0 holds the receiver idle (e.g. while sending)
  input  logic       dp_i,
  input  logic       dm_i,
  // Packet byte stream (single clock strobes, no back pressure)
  output logic [7:0] data_o,
  output logic       valid_o,
  output logic       last_o,
  output logic       err_o,          // valid with last_o: packet had an error
  // Status
  output logic       active_o,       // packet reception in progress
  output logic       good_o,         // one clock: good packet received
  output logic       bad_o,          // one clock: bad packet received
  output logic       reset_o,        // one clock: bus reset detected
  output logic [1:0] line_o          // synchronized {D+, D-}
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  // Bit period in 8.8 fixed point clocks: 12 Mbit/s
  localparam logic [63:0] P64 = (64'(CLK_HZ) * 64'd256 + 64'd6_000_000) / 64'd12_000_000;
  localparam logic [23:0] P     = P64[23:0];
  localparam logic [23:0] HALF  = P >> 1;
  // Pipeline latency: the edge strobe is seen 3 clocks after the pin change
  // (2 flop synchronizer + 1 compare stage) and the sampled level lags the
  // pin by 3 clocks (2 flops + ls register). The sample strobe is therefore
  // placed HALF + 3 clocks after the pin edge (wrapped into one bit).
  localparam logic [23:0] LAG   = 24'd768;
  localparam logic [23:0] TH_RAW = HALF + 24'd768;
  localparam logic [23:0] TH    = (TH_RAW >= P) ? (TH_RAW - P) : TH_RAW;
  localparam int RST_CLKS = (CLK_HZ / 400_000);    // 2.5 us in clocks

  localparam logic [1:0] LS_J = 2'b10, LS_K = 2'b01, LS_SE0 = 2'b00;

  // ---------------- Input synchronizers and line state ----------------
  (* async_reg = "true" *) logic [1:0] dp_q, dm_q;
  logic [1:0] ls, ls_d;                 // {dp,dm}, synchronized and delayed
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dp_q <= 2'b11; dm_q <= 2'b00; ls <= LS_J; ls_d <= LS_J;
    end else begin
      dp_q <= {dp_q[0], dp_i};
      dm_q <= {dm_q[0], dm_i};
      ls   <= {dp_q[1], dm_q[1]};
      ls_d <= ls;
    end
  end
  assign line_o = ls;
  wire edge_det = ({dp_q[1], dm_q[1]} != ls);        // earliest possible edge flag

  // ---------------- Bit clock recovery (sample strobe mid-bit) ----------------
  logic [23:0] ph;
  logic        samp;
  wire  [23:0] ph_lin = ph + 24'd256;
  wire  [23:0] ph_n   = (ph_lin >= P) ? (ph_lin - P) : ph_lin;   // next phase
  wire  [23:0] d_th   = (ph_n >= TH) ? (ph_n - TH) : (ph_n + P - TH);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ph <= '0; samp <= 1'b0;
    end else begin
      samp <= 1'b0;
      if (edge_det) ph <= LAG;                      // restart phase at an edge
      else begin
        ph <= ph_n;
        if (d_th < 24'd256) samp <= 1'b1;           // phase passes the sample point
      end
    end
  end

  // ---------------- Bus reset detection (long SE0) ----------------
  logic [15:0] se0_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin se0_cnt <= '0; reset_o <= 1'b0; end
    else begin
      reset_o <= 1'b0;
      if (ls == LS_SE0) begin
        if (se0_cnt != 16'hFFFF) se0_cnt <= se0_cnt + 16'd1;
        if (se0_cnt == 16'(RST_CLKS)) reset_o <= 1'b1;
      end else se0_cnt <= '0;
    end
  end

  // ---------------- Packet receive state machine ----------------
  typedef enum logic [1:0] { R_IDLE, R_SYNC, R_DATA, R_WAITJ } rstate_t;
  rstate_t     state;
  logic [1:0]  prev;                  // previous sampled J/K state
  logic [3:0]  zeros;                 // SYNC zero counter
  logic [2:0]  ones;                  // consecutive ones (stuffing)
  logic [7:0]  sh;                    // shift register (LSB first)
  logic [2:0]  bitcnt;
  logic        first;                 // next byte is the PID
  logic        stuff_err, pid_ok, is_data, is_tok, in_pay;
  logic [15:0] crc16;
  logic [4:0]  crc5;
  logic [7:0]  h0, h1, h2;            // hold pipeline (removes trailing CRC16)
  logic [1:0]  hcnt;
  logic [10:0] nbytes;                // bytes after the PID
  logic        misalign;

  wire         is_jk  = (ls == LS_J) || (ls == LS_K);
  wire         d_bit  = (ls == prev);                 // NRZI: same = 1
  wire  [7:0]  nb     = {d_bit, sh[7:1]};             // byte when complete
  wire  [1:0]  hneed  = is_data ? 2'd3 : 2'd1;        // bytes to hold back
  wire         crc16_fb = crc16[0] ^ d_bit;
  wire         crc5_fb  = crc5[0] ^ d_bit;

  // Error evaluation at EOP
  wire crc_ok = is_data ? (crc16 == 16'hB001 && nbytes >= 11'd2) :
                is_tok  ? (crc5 == 5'h06 && nbytes == 11'd2) :
                          (nbytes == 11'd0);
  wire pkt_bad = stuff_err | ~pid_ok | misalign | ~crc_ok;

  assign active_o = (state == R_SYNC) || (state == R_DATA);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= R_IDLE; prev <= LS_J; zeros <= '0; ones <= '0; sh <= '0;
      bitcnt <= '0; first <= 1'b1; stuff_err <= 1'b0; pid_ok <= 1'b0;
      is_data <= 1'b0; is_tok <= 1'b0; in_pay <= 1'b0; crc16 <= 16'hFFFF;
      crc5 <= 5'h1F; h0 <= '0; h1 <= '0; h2 <= '0; hcnt <= '0; nbytes <= '0;
      misalign <= 1'b0; data_o <= '0; valid_o <= 1'b0; last_o <= 1'b0;
      err_o <= 1'b0; good_o <= 1'b0; bad_o <= 1'b0;
    end else begin
      valid_o <= 1'b0; last_o <= 1'b0; err_o <= 1'b0;
      good_o  <= 1'b0; bad_o  <= 1'b0;
      if (!enable_i) begin
        state <= R_WAITJ;                                  // ignore the bus
      end else if (samp) begin
        case (state)
          R_IDLE: if (ls == LS_K) begin                    // first SYNC bit
            prev <= LS_K; zeros <= 4'd1; state <= R_SYNC;
          end
          R_SYNC: begin
            if (is_jk) begin
              prev <= ls;
              if (!d_bit) begin
                if (zeros != 4'hF) zeros <= zeros + 4'd1;
              end else if (zeros >= 4'd5) begin            // SYNC found
                state <= R_DATA; ones <= 3'd1; bitcnt <= '0; first <= 1'b1;
                stuff_err <= 1'b0; in_pay <= 1'b0; crc16 <= 16'hFFFF;
                crc5 <= 5'h1F; hcnt <= '0; nbytes <= '0; misalign <= 1'b0;
                pid_ok <= 1'b0; is_data <= 1'b0; is_tok <= 1'b0;
              end else state <= R_WAITJ;                   // bad SYNC
            end else state <= R_WAITJ;
          end
          R_DATA: begin
            if (ls == LS_SE0) begin                        // EOP
              misalign <= 1'b0;
              if (hcnt == hneed) begin                     // flush last byte
                data_o  <= h0; valid_o <= 1'b1; last_o <= 1'b1;
                err_o   <= pkt_bad | (bitcnt != 3'd0);
                good_o  <= ~(pkt_bad | (bitcnt != 3'd0));
                bad_o   <=  (pkt_bad | (bitcnt != 3'd0));
              end else bad_o <= 1'b1;                      // truncated packet
              state <= R_WAITJ;
            end else if (!is_jk) begin                     // SE1: illegal
              bad_o <= 1'b1; state <= R_WAITJ;
            end else begin
              prev <= ls;
              if (ones == 3'd6) begin                      // stuffed bit
                ones <= '0;
                if (d_bit) stuff_err <= 1'b1;
              end else begin
                ones <= d_bit ? ones + 3'd1 : 3'd0;
                sh   <= nb;
                if (in_pay) begin                          // running CRCs
                  crc16 <= {1'b0, crc16[15:1]} ^ (crc16_fb ? 16'hA001 : 16'h0);
                  crc5  <= {1'b0, crc5[4:1]}   ^ (crc5_fb  ? 5'h14   : 5'h00);
                end
                bitcnt <= bitcnt + 3'd1;
                if (bitcnt == 3'd7) begin                  // byte complete
                  if (first) begin                         // PID byte
                    first  <= 1'b0; in_pay <= 1'b1;
                    pid_ok <= (nb[7:4] == ~nb[3:0]);
                    is_data <= (nb[1:0] == 2'b11);
                    is_tok  <= (nb[1:0] == 2'b01) || (nb[3:0] == 4'b0100);
                    h0 <= {4'h0, nb[3:0]}; hcnt <= 2'd1;
                  end else begin
                    nbytes <= nbytes + 11'd1;
                    if (hcnt != hneed) begin               // still filling
                      if (hcnt == 2'd1) h1 <= nb; else h2 <= nb;
                      hcnt <= hcnt + 2'd1;
                    end else begin                         // emit oldest byte
                      data_o <= h0; valid_o <= 1'b1;
                      if (is_data) begin h0 <= h1; h1 <= h2; h2 <= nb; end
                      else         h0 <= nb;
                    end
                  end
                end
              end
            end
          end
          R_WAITJ: if (ls == LS_J) begin
            state <= R_IDLE; prev <= LS_J;
          end
          default: state <= R_IDLE;
        endcase
      end
    end
  end
endmodule
