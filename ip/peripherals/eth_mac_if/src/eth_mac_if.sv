// ***************
// Filename: eth_mac_if.sv
// Author: FPGA Cores 4 U
// Description: Ethernet MAC interface (GMII, 8 bit, single clock). Version
//   1.0.0. Transmit - takes an AXI-Stream frame (destination MAC onward,
//   no preamble or FCS) and drives GMII with 7 preamble bytes and the
//   start-of-frame delimiter, the frame data, zero padding up to MIN_FRAME
//   bytes before the FCS (60 by default), the CRC-32 frame check sequence
//   (low byte first) and a 12 byte inter-frame gap. The source must
//   deliver the frame without gaps (put a packet_fifo in front): a gap
//   aborts the frame with gmii_tx_er and underrun_o. Receive - finds the
//   start-of-frame delimiter, removes the FCS, streams the frame to an
//   AXI-Stream master (tlast on the last data byte, tuser high on that
//   beat when the frame is bad - FCS mismatch, gmii_rx_er, or shorter than
//   64 bytes including FCS) and pulses crc_err_o / short_o / rx_err_o. The
//   receiver cannot stall the wire: a byte presented while m_axis_tready
//   is low is lost and overflow_o pulses. Use with 125 MHz GMII (or a 100
//   MHz clock at 100 Mbit/s with tx/rx clock enables outside this block);
//   no MDIO, no flow control. Clock - clk shared by transmit and receive.
//   Reset - synchronous aresetn, idle, gmii_tx_en low. Latency - transmit:
//   8 preamble clocks plus 1; receive: 6 bytes (FCS removal plus output
//   register). Errors - underrun_o, overflow_o, crc_err_o, short_o,
//   rx_err_o as described.
// Date: 2026-09-29
module eth_mac_if #(
  parameter int MIN_FRAME = 60,
  parameter int IFG_BYTES = 12
) (
  input  logic       clk,
  input  logic       aresetn,
  // AXI-Stream transmit
  input  logic [7:0] s_axis_tdata,
  input  logic       s_axis_tlast,
  input  logic       s_axis_tvalid,
  output logic       s_axis_tready,
  // AXI-Stream receive
  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tlast,
  output logic       m_axis_tuser,     // with tlast: frame is bad
  output logic       m_axis_tvalid,
  input  logic       m_axis_tready,
  // GMII
  output logic [7:0] gmii_txd,
  output logic       gmii_tx_en,
  output logic       gmii_tx_er,
  input  logic [7:0] gmii_rxd,
  input  logic       gmii_rx_dv,
  input  logic       gmii_rx_er,
  // status pulses
  output logic       underrun_o,
  output logic       overflow_o,
  output logic       crc_err_o,
  output logic       short_o,
  output logic       rx_err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (MIN_FRAME < 1 || IFG_BYTES < 1) begin : g_bad $error("eth_mac_if: bad parameters"); end
  // ============================ transmit ============================
  typedef enum logic [2:0] {T_IDLE, T_PRE, T_DATA, T_PAD, T_FCS, T_IFG} tstate_t; tstate_t ts;
  logic [15:0] tcnt; logic [2:0] pcnt; logic [1:0] fcnt; logic [7:0] tcrc_d; logic tcrc_v, tcrc_i; logic [31:0] tcrc;
  crc32 #(.DATA_W(8)) u_tcrc (.clk, .rst_n(aresetn), .init_i(tcrc_i), .valid_i(tcrc_v), .data_i(tcrc_d), .keep_i(1'b1), .crc_o(tcrc));
  assign s_axis_tready = (ts == T_DATA);
  always_comb begin
    tcrc_i = (ts == T_IDLE) | (ts == T_PRE);
    tcrc_v = 1'b0; tcrc_d = 8'h00;
    if (ts == T_DATA && s_axis_tvalid) begin tcrc_v = 1'b1; tcrc_d = s_axis_tdata; end
    if (ts == T_PAD) begin tcrc_v = 1'b1; tcrc_d = 8'h00; end
  end
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      ts <= T_IDLE; tcnt <= '0; pcnt <= '0; fcnt <= '0; gmii_txd <= '0; gmii_tx_en <= 1'b0; gmii_tx_er <= 1'b0; underrun_o <= 1'b0;
    end else begin
      underrun_o <= 1'b0; gmii_tx_er <= 1'b0;
      case (ts)
        T_IDLE: begin gmii_tx_en <= 1'b0; if (s_axis_tvalid) begin ts <= T_PRE; pcnt <= '0; end end
        T_PRE: begin
          gmii_tx_en <= 1'b1; gmii_txd <= (pcnt == 3'd7) ? 8'hD5 : 8'h55; pcnt <= pcnt + 1'b1;
          if (pcnt == 3'd7) begin ts <= T_DATA; tcnt <= '0; end
        end
        T_DATA: begin
          if (s_axis_tvalid) begin
            gmii_txd <= s_axis_tdata; gmii_tx_en <= 1'b1; tcnt <= tcnt + 1'b1;
            if (s_axis_tlast) ts <= (tcnt + 1 >= MIN_FRAME) ? T_FCS : T_PAD;
            fcnt <= '0;
          end else begin                                      // source gap: abort
            gmii_tx_en <= 1'b0; gmii_tx_er <= 1'b1; underrun_o <= 1'b1; ts <= T_IFG; tcnt <= '0;
          end
        end
        T_PAD: begin
          gmii_txd <= 8'h00; gmii_tx_en <= 1'b1; tcnt <= tcnt + 1'b1; fcnt <= '0;
          if (tcnt + 1 >= MIN_FRAME) ts <= T_FCS;
        end
        T_FCS: begin
          gmii_tx_en <= 1'b1; gmii_txd <= tcrc[fcnt*8 +: 8]; fcnt <= fcnt + 1'b1;
          if (fcnt == 2'd3) begin ts <= T_IFG; tcnt <= '0; end
        end
        T_IFG: begin
          gmii_tx_en <= 1'b0; tcnt <= tcnt + 1'b1;
          if (tcnt + 1 >= IFG_BYTES) ts <= T_IDLE;
        end
        default: ts <= T_IDLE;
      endcase
    end
  end
  // ============================ receive ============================
  typedef enum logic [1:0] {R_IDLE, R_DATA} rstate_t; rstate_t rs;
  logic [7:0] rxd_q; logic dv_q, er_q;
  logic [31:0] win; logic [15:0] rn; logic [7:0] pend_d; logic pend_v, rerr;
  logic rcrc_i, rcrc_v; logic [7:0] rcrc_d; logic [31:0] rcrc;
  crc32 #(.DATA_W(8)) u_rcrc (.clk, .rst_n(aresetn), .init_i(rcrc_i), .valid_i(rcrc_v), .data_i(rcrc_d), .keep_i(1'b1), .crc_o(rcrc));
  always_ff @(posedge clk) begin
    if (!aresetn) begin rxd_q <= '0; dv_q <= 1'b0; er_q <= 1'b0; end
    else begin rxd_q <= gmii_rxd; dv_q <= gmii_rx_dv; er_q <= gmii_rx_er; end
  end
  always_comb begin
    rcrc_i = (rs == R_IDLE); rcrc_v = 1'b0; rcrc_d = win[7:0];
    if (rs == R_DATA && dv_q && rn >= 4) rcrc_v = 1'b1;
  end
  wire bad_crc = (win != rcrc);
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      rs <= R_IDLE; win <= '0; rn <= '0; pend_d <= '0; pend_v <= 1'b0; rerr <= 1'b0;
      m_axis_tdata <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0; m_axis_tvalid <= 1'b0;
      overflow_o <= 1'b0; crc_err_o <= 1'b0; short_o <= 1'b0; rx_err_o <= 1'b0;
    end else begin
      m_axis_tvalid <= 1'b0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
      overflow_o <= 1'b0; crc_err_o <= 1'b0; short_o <= 1'b0; rx_err_o <= 1'b0;
      if (m_axis_tvalid && !m_axis_tready) overflow_o <= 1'b1;
      case (rs)
        R_IDLE: begin
          rn <= '0; pend_v <= 1'b0; rerr <= 1'b0;
          if (dv_q && rxd_q == 8'hD5) rs <= R_DATA;
        end
        R_DATA: begin
          if (dv_q) begin
            if (er_q) rerr <= 1'b1;
            if (rn >= 4) begin
              if (pend_v) begin m_axis_tvalid <= 1'b1; m_axis_tdata <= pend_d; end
              pend_d <= win[7:0]; pend_v <= 1'b1;
            end
            win <= {rxd_q, win[31:8]}; rn <= rn + 1'b1;
          end else begin                                       // end of frame
            rs <= R_IDLE;
            begin
              logic bad, sh, cerr;
              cerr = (rn >= 4) && bad_crc; sh = (rn < 64); bad = cerr | sh | rerr;
              if (pend_v) begin m_axis_tvalid <= 1'b1; m_axis_tdata <= pend_d; m_axis_tlast <= 1'b1; m_axis_tuser <= bad; end
              crc_err_o <= cerr; short_o <= sh; rx_err_o <= rerr;
            end
          end
        end
        default: rs <= R_IDLE;
      endcase
    end
  end
endmodule
