// ***************
// Filename: axis_dma.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream DMA with two independent channels sharing one
//   AXI4 master port. MM2S reads LEN bytes from memory and emits them on
//   an AXI-Stream master (tlast on the last word). S2MM accepts an AXI-
//   Stream slave and writes LEN bytes to memory. Both use burst engines
//   limited to MAX_BURST beats and 4 KB boundaries, with FIFOs on the
//   stream sides. AXI-Lite map - 0x00 CTRL [0]mm2s_start [1]s2mm_start
//   (pulses) [2]irq_en, 0x04 MM2S_ADDR, 0x08 MM2S_LEN, 0x0C S2MM_ADDR,
//   0x10 S2MM_LEN, 0x14 STATUS [0]mm2s_busy [1]s2mm_busy [8]mm2s_done
//   [9]s2mm_done [10]mm2s_err [11]s2mm_err, done and error bits are W1C.
//   Version 1.0.0. Clock - single clock aclk, every input is synchronous
//   to it unless a two-flop synchronizer is mentioned. Reset - synchronous
//   active low aresetn, registers take the documented reset values.
//   Latency - AXI-Lite write response and read data follow the request by
//   about 2 to 3 clocks (ip_axil_regs, registered read path). Timing -
//   registered outputs, no combinational path from the bus to the pins.
//   Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error. The AXI4 master
//   follows the AXI4 rules of 4 KB burst boundaries; a bus error response
//   stops the transfer and is reported in STATUS.
// Date: 2026-09-29

module axis_dma #(
  parameter int MAX_BURST  = 16,
  parameter int FIFO_DEPTH = 64
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
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
  // AXI4 memory-mapped master (32 bit data)
  output logic [31:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [31:0] m_axi_wdata,
  output logic [3:0]  m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [31:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,
  // MM2S stream out (memory -> stream)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // S2MM stream in (stream -> memory)
  input  logic [31:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  output logic        irq_o
);
