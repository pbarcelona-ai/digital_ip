// ***************
// Filename: pcie_tl_ep_top.sv
// Author: FPGA Cores 4 U
// Description: PCIe transaction layer endpoint IP top level. 64 bit AXI-
//   Stream TLP ports (rx from and tx to a PCIe link core such as a hard
//   block), Type 0 config space, BAR0 with block RAM and a stream window,
//   plus AXI-Stream user ports - s_axis words are DMA written to host memory
//   as Memory Write TLPs, m_axis carries payload written to the BAR0 stream
//   window. AXI-Lite map - 0x00 CTRL[0]=dma_en; 0x04/0x08 DMA_ADDR lo/hi;
//   0x0C DMA_LEN_DW; 0x10 STATUS [0]mem_en [1]bus_master [2]dma_busy; 0x14
//   CPL_ID; 0x18 BAR0; 0x1C RX_TLP; 0x20 MWR; 0x24 MRD; 0x28 CFG; 0x2C UR;
//   0x30 DMA_TLP counters. PHY, LTSSM and data link layer are not included.
//   Version 1.0.0. Scope - transaction layer only (no PHY, data link layer,
//   LTSSM, credit or flow-control logic; a link core must supply the TLP
//   stream). Clock - aclk (250 MHz class for a Gen2 x4 link core, 100 MHz
//   used in simulation), everything synchronous. Reset - synchronous aresetn,
//   DMA idle, counters cleared, BAR RAM contents undefined. Latency - a
//   memory read is answered with a completion about 5 clocks after the
//   request TLP ends; a memory write reaches the RAM 2 clocks after the last
//   beat. Errors - unsupported requests are answered with an Unsupported
//   Request completion and counted (UR counter); illegal parameters stop
//   elaboration.
// Date: 2026-09-29

module pcie_tl_ep_top #(
  parameter logic [15:0] VENDOR_ID = 16'h1234,
  parameter logic [15:0] DEVICE_ID = 16'h5678,
  parameter int          BAR_BITS  = 13,
  parameter int          RAM_DW    = 1024,
  parameter int          FIFO_DEPTH = 512
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // TLP receive (from link)
  input  logic [63:0] rx_axis_tdata,
  input  logic [7:0]  rx_axis_tkeep,
  input  logic        rx_axis_tlast,
  input  logic        rx_axis_tvalid,
  output logic        rx_axis_tready,
  // TLP transmit (to link)
  output logic [63:0] tx_axis_tdata,
  output logic [7:0]  tx_axis_tkeep,
  output logic        tx_axis_tlast,
  output logic        tx_axis_tvalid,
  input  logic        tx_axis_tready,
  // User stream into DMA (device -> host)
  input  logic [31:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // User stream from BAR0 stream window (host -> device)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast
);
