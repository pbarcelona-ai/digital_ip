// ***************
// Filename: ip_reset_sync_top.sv
// Author: FPGA Cores 4 U
// Description: Top level of the reset synchronizer IP. Synchronizes an
//   asynchronous external reset for the AXI-Lite bus and for NUM_OUT
//   replicated user resets (fan-out control). A software reset bit, hold-
//   time register, reset event counter and status are exposed through an
//   AXI-Lite register file. Register map - 0x00 CTRL[0]=soft reset (self
//   clearing), 0x04 HOLD cycles, 0x08 STATUS[0]=active [1]=event seen
//   (W1C), 0x0C event count. Version 1.0.0. Clock - aclk, the external
//   reset arst_i is asynchronous and is synchronized with STAGES flops.
//   Reset - the reset asserts asynchronously and releases synchronously;
//   outputs are held for HOLD_DEFAULT clocks or the programmed hold.
//   Latency - release is STAGES+1 clocks after arst_i deasserts plus the
//   hold. Errors - illegal parameters stop elaboration; out of range AXI-
//   Lite accesses return SLVERR.
// Date: 2026-09-29

module ip_reset_sync_top #(
  parameter int STAGES        = 3,
  parameter int NUM_OUT       = 4,     // replicated reset outputs
  parameter bit ACTIVE_LOW_IN = 1,
  parameter bit ACTIVE_LOW_OUT= 1,
  parameter int HOLD_DEFAULT  = 16     // default stretch in clocks
) (
  input  logic        aclk,
  input  logic        arst_i,           // external asynchronous reset
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
  // Reset outputs
  output logic [NUM_OUT-1:0] rst_o,
  output logic        bus_rst_n_o       // synchronized reset for AXI logic
);
