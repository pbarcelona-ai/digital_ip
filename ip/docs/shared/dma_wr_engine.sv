// ***************
// Filename: dma_wr_engine.sv
// Author: FPGA Cores 4 U
// Description: AXI4 write burst engine for the DMA IPs. Consumes an AXI-
//   Stream of 32-bit words and writes NWORDS words to a word-aligned address
//   using INCR bursts of up to MAX_BURST beats that never cross a 4 KB
//   boundary. Completion is reported after the last write response. Sticky
//   error flag when any write response is not OKAY. Version 1.0.0. Helper
//   block of its IP; see the top level description for clock, reset, latency
//   and error behavior. Clock - the clock of the parent block, all signals
//   are synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
//   are synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29

module dma_wr_engine #(
  parameter int ADDR_W    = 32,
  parameter int MAX_BURST = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [23:0]       nwords_i,
  output logic              busy_o,
  output logic              done_o,
  output logic              err_o,
  // Stream in
  input  logic [31:0]       s_tdata,
  input  logic              s_tvalid,
  output logic              s_tready,
  // AXI4 write master
  output logic [ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]        m_axi_awlen,
  output logic [2:0]        m_axi_awsize,
  output logic [1:0]        m_axi_awburst,
  output logic              m_axi_awvalid,
  input  logic              m_axi_awready,
  output logic [31:0]       m_axi_wdata,
  output logic [3:0]        m_axi_wstrb,
  output logic              m_axi_wlast,
  output logic              m_axi_wvalid,
  input  logic              m_axi_wready,
  input  logic [1:0]        m_axi_bresp,
  input  logic              m_axi_bvalid,
  output logic              m_axi_bready
);
