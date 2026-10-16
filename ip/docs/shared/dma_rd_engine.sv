// ***************
// Filename: dma_rd_engine.sv
// Author: FPGA Cores 4 U
// Description: AXI4 read burst engine for the DMA IPs. Reads NWORDS 32-bit
//   words starting at a word-aligned address using INCR bursts of up to
//   MAX_BURST beats that never cross a 4 KB boundary, and streams the data
//   out on an AXI-Stream master (tlast on the final word). Reports busy, a
//   done pulse and a sticky error flag when any read response is not OKAY.
//   Version 1.0.0. Helper block of its IP; see the top level description for
//   clock, reset, latency and error behavior. Clock - the clock of the parent
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29

module dma_rd_engine #(
  parameter int ADDR_W    = 32,
  parameter int MAX_BURST = 16          // beats per burst (<= 256)
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,    // pulse, accepted when idle
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [23:0]       nwords_i,
  output logic              busy_o,
  output logic              done_o,     // one clock
  output logic              err_o,      // sticky until next start
  // AXI4 read master
  output logic [ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]        m_axi_arlen,
  output logic [2:0]        m_axi_arsize,
  output logic [1:0]        m_axi_arburst,
  output logic              m_axi_arvalid,
  input  logic              m_axi_arready,
  input  logic [31:0]       m_axi_rdata,
  input  logic [1:0]        m_axi_rresp,
  input  logic              m_axi_rlast,
  input  logic              m_axi_rvalid,
  output logic              m_axi_rready,
  // Stream out
  output logic [31:0]       m_tdata,
  output logic              m_tvalid,
  input  logic              m_tready,
  output logic              m_tlast
);
