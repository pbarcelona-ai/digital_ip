// ***************
// Filename: intc_top.sv
// Author: FPGA Cores 4 U
// Description: Interrupt controller IP with NUM_IRQ sources. Each source
//   has enable, edge or level type, polarity, and software set. Edge
//   sources latch into a pending register cleared by write-1-to-clear,
//   level sources follow the input. A lowest-index-wins priority encoder
//   reports the active vector (pipelined) and the irq output. Map - 0x00
//   ENABLE, 0x04 EDGE_TYPE, 0x08 ACTIVE_LOW, 0x0C PENDING (W1C for edge
//   bits), 0x10 SOFT_SET (write), 0x14 VECTOR [4:0]=id [31]=valid, 0x18
//   MASKED_PENDING. Version 1.0.0. Clock - single clock aclk, every input
//   is synchronous to it unless a two-flop synchronizer is mentioned.
//   Reset - synchronous active low aresetn, registers take the documented
//   reset values. Latency - AXI-Lite write response and read data follow
//   the request by about 2 to 3 clocks (ip_axil_regs, registered read
//   path). Timing - registered outputs, no combinational path from the bus
//   to the pins. Errors - out of range AXI-Lite accesses return SLVERR;
//   illegal parameter values stop elaboration with an $error.
// Date: 2026-09-29

module intc_top #(
  parameter int NUM_IRQ = 16             // number of sources (<= 32)
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
  input  logic [NUM_IRQ-1:0] irq_i,
  output logic               irq_o
);
