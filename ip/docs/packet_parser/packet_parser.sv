// ***************
// Filename: packet_parser.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream packet parser and filter. Version 1.0.0.
//   Captures the first HDR_BYTES of every packet (HDR_BYTES must be a
//   multiple of the stream width so headers are beat aligned) into hdr_o
//   and pulses hdr_valid_o when the header is complete, then either strips
//   the header (STRIP=1) or forwards it (STRIP=0) and forwards the
//   payload. A run-time filter compares the header with cfg_value_i under
//   cfg_mask_i; with drop_nomatch_i set, packets that do not match are
//   consumed and their payload is discarded (drop_o pulses at the last
//   beat), so only accepted packets reach the master port. With STRIP=0
//   the header beats are forwarded before the match is known and only the
//   payload is filtered. Every packet also reports its byte length (tkeep
//   aware) on len_o / len_valid_o, and packets that end before the header
//   is complete are flagged with runt_o and produce no output. Clock -
//   aclk. Reset - synchronous aresetn, idle, outputs low. Latency - 0
//   clocks (combinational valid/ready pass-through of accepted payload
//   beats); hdr_o and flags are registered, 1 clock after the header's
//   last beat. Errors - runt_o, drop_o; HDR_BYTES not a multiple of
//   DATA_W/8 rejected at elaboration.
// Date: 2026-09-29

module packet_parser #(
  parameter int DATA_W    = 32,
  parameter int HDR_BYTES = 8,
  parameter bit STRIP     = 1'b1
) (
  input  logic                       aclk,
  input  logic                       aresetn,
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
  // header and status
  output logic [HDR_BYTES*8-1:0]     hdr_o,
  output logic                       hdr_valid_o,
  output logic                       match_o,
  input  logic [HDR_BYTES*8-1:0]     cfg_mask_i,
  input  logic [HDR_BYTES*8-1:0]     cfg_value_i,
  input  logic                       drop_nomatch_i,
  output logic [15:0]                len_o,
  output logic                       len_valid_o,
  output logic                       runt_o,
  output logic                       drop_o
);
