// ***************
// Filename: axi4_lite_mux.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite 1-to-N interconnect (address decoded mux).
//   Version 1.0.0. One AXI-Lite slave port is routed to NSLAVE master
//   ports selected by axi4_lite_decoder (BASE/MASK regions). Addresses are
//   passed through unchanged. One write and one read may be outstanding at
//   a time (reads and writes are independent). Accesses that hit no region
//   are answered directly with DECERR (bresp/rresp = 2'b11, read data 0)
//   and never reach a slave. Master-port signals are packed vectors (slave
//   i uses slice i). Clock - aclk. Reset - synchronous aresetn, idle.
//   Latency - 1 clock for write/read address acceptance plus 1 clock for
//   the response beat on top of the slave latency. Timing - decoder output
//   is registered before use. Errors - DECERR for unmapped addresses; an
//   ill-formed region map is rejected by the decoder at elaboration.
// Date: 2026-09-29

module axi4_lite_mux #(
  parameter int ADDR_W = 32,
  parameter int NSLAVE = 4,
  parameter logic [NSLAVE*ADDR_W-1:0] BASE = {32'h0000_3000, 32'h0000_2000, 32'h0000_1000, 32'h0000_0000},
  parameter logic [NSLAVE*ADDR_W-1:0] MASK = {4{32'hFFFF_F000}}
) (
  input  logic                       aclk,
  input  logic                       aresetn,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  output logic [NSLAVE*ADDR_W-1:0]   m_axil_awaddr,
  output logic [NSLAVE-1:0]          m_axil_awvalid,
  input  logic [NSLAVE-1:0]          m_axil_awready,
  output logic [NSLAVE*32-1:0]       m_axil_wdata,
  output logic [NSLAVE*4-1:0]        m_axil_wstrb,
  output logic [NSLAVE-1:0]          m_axil_wvalid,
  input  logic [NSLAVE-1:0]          m_axil_wready,
  input  logic [NSLAVE*2-1:0]        m_axil_bresp,
  input  logic [NSLAVE-1:0]          m_axil_bvalid,
  output logic [NSLAVE-1:0]          m_axil_bready,
  output logic [NSLAVE*ADDR_W-1:0]   m_axil_araddr,
  output logic [NSLAVE-1:0]          m_axil_arvalid,
  input  logic [NSLAVE-1:0]          m_axil_arready,
  input  logic [NSLAVE*32-1:0]       m_axil_rdata,
  input  logic [NSLAVE*2-1:0]        m_axil_rresp,
  input  logic [NSLAVE-1:0]          m_axil_rvalid,
  output logic [NSLAVE-1:0]          m_axil_rready
);
