// ***************
// Filename: packet_fifo.sv
// Author: FPGA Cores 4 U
// Description: Packet-preserving FIFO (store and forward). Version 1.0.0.
//   Words are written with s_last_i marking the final word of a packet. A
//   packet becomes visible on the master side only when its last word has
//   been stored, so downstream logic never sees a partial packet. If the
//   FIFO fills in the middle of a packet the whole packet is discarded
//   (the write pointer is rolled back at the packet end) and drop_o
//   pulses; s_ready_o stays high in that case so the source is never
//   blocked mid-packet. A packet larger than the FIFO is therefore always
//   dropped. Optional DROP_ON_BAD: s_bad_i on the last word drops the
//   packet (e.g. CRC error). Clock - clk. Reset - synchronous active low.
//   Latency - a packet appears 2 clocks after its last word; words stream
//   1 per clock afterwards. Storage - block RAM. Errors - drop_o (pulse),
//   pkt_count_o; DEPTH must be a power of two >= 4.
// Date: 2026-09-29

module packet_fifo #(
  parameter int WIDTH        = 32,
  parameter int DEPTH        = 512,
  parameter bit DROP_ON_BAD  = 1'b1
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [WIDTH-1:0]         s_data_i,
  input  logic                     s_valid_i,
  output logic                     s_ready_o,
  input  logic                     s_last_i,
  input  logic                     s_bad_i,        // with s_last_i: drop this packet
  output logic [WIDTH-1:0]         m_data_o,
  output logic                     m_valid_o,
  input  logic                     m_ready_i,
  output logic                     m_last_o,
  output logic                     drop_o,         // one clock per dropped packet
  output logic [$clog2(DEPTH):0]   pkt_count_o     // complete packets stored
);
