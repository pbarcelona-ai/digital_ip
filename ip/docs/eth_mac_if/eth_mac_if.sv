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
