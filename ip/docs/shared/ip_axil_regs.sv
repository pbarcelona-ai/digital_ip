// ***************
// Filename: ip_axil_regs.sv
// Author: FPGA Cores 4 U
// Description: Generic AXI4-Lite slave register file. Provides NREG 32-bit
//   read/write registers with byte strobes, one-cycle write pulses, the
//   last written word, and a registered read-data path for timing closure.
//   Read data is supplied by the parent so status and control registers
//   can share one address map. Out of range accesses return SLVERR. Single
//   clock, active-low synchronous reset. Version 1.0.0. Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29

module ip_axil_regs #(
  parameter int ADDR_W = 8,                       // AXI-Lite address bits
  parameter int NREG   = 8,                       // number of 32-bit regs
  parameter logic [NREG*32-1:0] RESET_VALS = '0   // power-up register values
) (
  input  logic                 aclk,
  input  logic                 aresetn,
  // Write address channel
  input  logic [ADDR_W-1:0]    s_axil_awaddr,
  input  logic                 s_axil_awvalid,
  output logic                 s_axil_awready,
  // Write data channel
  input  logic [31:0]          s_axil_wdata,
  input  logic [3:0]           s_axil_wstrb,
  input  logic                 s_axil_wvalid,
  output logic                 s_axil_wready,
  // Write response channel
  output logic [1:0]           s_axil_bresp,
  output logic                 s_axil_bvalid,
  input  logic                 s_axil_bready,
  // Read address channel
  input  logic [ADDR_W-1:0]    s_axil_araddr,
  input  logic                 s_axil_arvalid,
  output logic                 s_axil_arready,
  // Read data channel
  output logic [31:0]          s_axil_rdata,
  output logic [1:0]           s_axil_rresp,
  output logic                 s_axil_rvalid,
  input  logic                 s_axil_rready,
  // Register interface to the IP core
  output logic [NREG*32-1:0]   reg_o,       // stored register values
  output logic [NREG-1:0]      wr_pulse_o,  // one-cycle pulse per write
  output logic [31:0]          wr_data_o,   // raw data of the last write
  input  logic [NREG*32-1:0]   rd_i         // value returned on reads
);
