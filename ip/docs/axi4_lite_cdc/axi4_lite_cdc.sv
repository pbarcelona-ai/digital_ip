// ***************
// Filename: axi4_lite_cdc.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite clock domain bridge. An AXI-Lite slave in the source
//   clock domain is connected to an AXI-Lite master in the destination domain
//   using a toggle request / toggle acknowledge handshake with two flop
//   synchronizers. One transaction is outstanding at a time; address, data
//   and response buses are held stable while the handshake crosses, so no
//   per-bit synchronization is needed. Works for any clock ratio. Version
//   1.0.0. Clocks - s_clk (slave side) and m_clk (master side) unrelated,
//   each channel crosses with a toggle handshake and two-flop synchronizers.
//   Reset - synchronous active low per domain, reset both together. Latency -
//   roughly 6 to 10 clocks of the slower domain per transaction; one
//   transaction outstanding at a time. Timing - address/data registers cross
//   under a max-delay constraint of one destination period. Errors - the
//   master side response (including SLVERR) is passed back unchanged; illegal
//   parameters stop elaboration. Clock - the clock of the parent block, all
//   signals are synchronous to it.
//   signals are synchronous to it.
// Date: 2026-09-29

module axi4_lite_cdc #(
  parameter int ADDR_W = 8
) (
  // Source domain: AXI-Lite slave
  input  logic              s_clk,
  input  logic              s_rst_n,
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
  // Destination domain: AXI-Lite master
  input  logic              m_clk,
  input  logic              m_rst_n,
  output logic [ADDR_W-1:0] m_axil_awaddr,
  output logic              m_axil_awvalid,
  input  logic              m_axil_awready,
  output logic [31:0]       m_axil_wdata,
  output logic [3:0]        m_axil_wstrb,
  output logic              m_axil_wvalid,
  input  logic              m_axil_wready,
  input  logic [1:0]        m_axil_bresp,
  input  logic              m_axil_bvalid,
  output logic              m_axil_bready,
  output logic [ADDR_W-1:0] m_axil_araddr,
  output logic              m_axil_arvalid,
  input  logic              m_axil_arready,
  input  logic [31:0]       m_axil_rdata,
  input  logic [1:0]        m_axil_rresp,
  input  logic              m_axil_rvalid,
  output logic              m_axil_rready
);
