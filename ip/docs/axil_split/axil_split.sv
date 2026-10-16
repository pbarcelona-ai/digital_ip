// ***************
// Filename: axil_split.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite 1-to-2 address decoder (interconnect).
//   Routes each transaction from one master port to one of two slave ports
//   by address bit SEL_BIT: bit = 0 -> port m0, bit = 1 -> port m1. The
//   full address is forwarded; each slave uses the low bits it needs.
//   One write and one read can be in flight at a time (independently).
//   AW and W may arrive in any order; they are held until both are present,
//   then issued together to the selected slave. Slave responses (BRESP /
//   RRESP / RDATA) are passed back unchanged.
//   Latency: 1-2 cycles per channel added to each transaction.
//   Dependencies: none
// Date: 2026-09-26

module axil_split #(
  parameter int ADDR_W  = 15,              // master address width
  parameter int SEL_BIT = ADDR_W - 1       // address bit that selects the port
)(
  input  logic              clk,
  input  logic              rst_n,
  // ---------------- slave port (from the master)
  input  logic [ADDR_W-1:0] s_awaddr,
  input  logic              s_awvalid,
  output logic              s_awready,
  input  logic [31:0]       s_wdata,
  input  logic [3:0]        s_wstrb,
  input  logic              s_wvalid,
  output logic              s_wready,
  output logic [1:0]        s_bresp,
  output logic              s_bvalid,
  input  logic              s_bready,
  input  logic [ADDR_W-1:0] s_araddr,
  input  logic              s_arvalid,
  output logic              s_arready,
  output logic [31:0]       s_rdata,
  output logic [1:0]        s_rresp,
  output logic              s_rvalid,
  input  logic              s_rready,
  // ---------------- master ports (to the two slaves), port i in slice i
  output logic [2*ADDR_W-1:0] m_awaddr,
  output logic [1:0]          m_awvalid,
  input  logic [1:0]          m_awready,
  output logic [63:0]         m_wdata,
  output logic [7:0]          m_wstrb,
  output logic [1:0]          m_wvalid,
  input  logic [1:0]          m_wready,
  input  logic [3:0]          m_bresp,
  input  logic [1:0]          m_bvalid,
  output logic [1:0]          m_bready,
  output logic [2*ADDR_W-1:0] m_araddr,
  output logic [1:0]          m_arvalid,
  input  logic [1:0]          m_arready,
  input  logic [63:0]         m_rdata,
  input  logic [3:0]          m_rresp,
  input  logic [1:0]          m_rvalid,
  output logic [1:0]          m_rready
);
