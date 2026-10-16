// ***************
// Filename: axi_stream_fifo.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream FIFO. Version 1.0.0. Buffers a full AXI-Stream
//   (tdata, tkeep, tlast, tuser) in a block-RAM FIFO of DEPTH beats with
//   standard valid/ready handshakes and a fill level. Built on
//   ip_axis_fifo (two-register output pipeline for timing). Clock - aclk.
//   Reset - synchronous aresetn, empty. Latency - 3 clocks from an input
//   beat to the output when empty. Throughput - one beat per clock.
//   Backpressure - s_axis_tready low when full; no data is ever dropped.
//   Errors - DEPTH must be a power of two >= 4 (rejected at elaboration);
//   USER_W >= 1.
// Date: 2026-09-29

module axi_stream_fifo #(
  parameter int DATA_W = 32,
  parameter int USER_W = 1,
  parameter int DEPTH  = 512
) (
  input  logic                    aclk,
  input  logic                    aresetn,
  input  logic [DATA_W-1:0]       s_axis_tdata,
  input  logic [DATA_W/8-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tlast,
  input  logic [USER_W-1:0]       s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  output logic [DATA_W-1:0]       m_axis_tdata,
  output logic [DATA_W/8-1:0]     m_axis_tkeep,
  output logic                    m_axis_tlast,
  output logic [USER_W-1:0]       m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic [$clog2(DEPTH)+1:0] level_o
);
