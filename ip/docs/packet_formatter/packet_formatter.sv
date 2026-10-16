// ***************
// Filename: packet_formatter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream packet formatter. Version 1.0.0. Builds outgoing
//   packets from a payload stream - a header of HDR_BYTES (sampled from
//   hdr_i when the first payload beat arrives, must be a multiple of the
//   stream width) is prepended, zero pad beats are appended until the
//   packet has at least MIN_BEATS beats, and an optional trailer beat
//   (trailer_i, sampled with the header) can be appended. tlast is moved
//   to the final inserted beat. Padding or a trailer requires the payload
//   length to be a multiple of the stream width (full tkeep on the last
//   payload beat); otherwise align_err_o pulses and the packet is sent
//   without tail. It is the inverse of packet_parser with STRIP=1. Clock -
//   aclk. Reset - synchronous aresetn, idle. Latency - 1 clock to start a
//   packet (header sampling), then one beat per clock; header beats stall
//   the payload input. Errors - align_err_o; misaligned HDR_BYTES rejected
//   at elaboration.
// Date: 2026-09-29

module packet_formatter #(
  parameter int DATA_W    = 32,
  parameter int HDR_BYTES = 8,
  parameter bit TRAILER   = 1'b0,
  parameter int MIN_BEATS = 0
) (
  input  logic                       aclk,
  input  logic                       aresetn,
  input  logic [HDR_BYTES*8-1:0]     hdr_i,
  input  logic [DATA_W-1:0]          trailer_i,
  input  logic [DATA_W-1:0]          s_axis_tdata,
  input  logic [DATA_W/8-1:0]        s_axis_tkeep,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  output logic [DATA_W-1:0]          m_axis_tdata,
  output logic [DATA_W/8-1:0]        m_axis_tkeep,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       align_err_o
);
