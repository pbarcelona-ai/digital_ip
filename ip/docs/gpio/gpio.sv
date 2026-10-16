// ***************
// Filename: gpio_top.sv
// Author: FPGA Cores 4 U
// Description: General purpose I/O IP with WIDTH pins. Per-pin direction,
//   output register with atomic SET/CLEAR/TOGGLE registers, two flop input
//   synchronizers, per-pin rising/falling edge interrupts with enable
//   masks and write-1-to-clear status, and an interrupt output. Tri-state
//   style pins (gpio_t=1 means input). Map - 0x00 OUT, 0x04 DIR(1=output),
//   0x08 IN (read only), 0x0C SET, 0x10 CLEAR, 0x14 TOGGLE, 0x18 INT_EN,
//   0x1C RISE_EN, 0x20 FALL_EN, 0x24 INT_STATUS (W1C). Version 1.0.0.
//   Clock - single clock aclk, every input is synchronous to it unless a
//   two-flop synchronizer is mentioned. Reset - synchronous active low
//   aresetn, registers take the documented reset values. Latency - AXI-
//   Lite write response and read data follow the request by about 2 to 3
//   clocks (ip_axil_regs, registered read path). Timing - registered
//   outputs, no combinational path from the bus to the pins. Errors - out
//   of range AXI-Lite accesses return SLVERR; illegal parameter values
//   stop elaboration with an $error.
// Date: 2026-09-29

module gpio_top #(
  parameter int WIDTH = 16               // number of pins (<= 32)
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
  input  logic [WIDTH-1:0] gpio_i,       // pad input
  output logic [WIDTH-1:0] gpio_o,       // pad output value
  output logic [WIDTH-1:0] gpio_t,       // pad tri-state (1 = high-Z input)
  output logic             irq_o
);
