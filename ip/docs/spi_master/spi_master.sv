// ***************
// Filename: spi_top.sv
// Author: FPGA Cores 4 U
// Description: SPI master IP top level. AXI-Stream slave carries words to
//   transmit (tlast ends a chip select burst), AXI-Stream master returns
//   the words captured from MISO. AXI-Lite map - 0x00 CTRL [0]en [1]cpol
//   [2]cpha [3]lsb_first [15:8]cs_select; 0x04 DIV (SCLK half period =
//   DIV+1 clocks); 0x08 WORD_LEN bits per word (1..DATA_W); 0x0C STATUS
//   [0]busy [1]rx_overrun (W1C) [31:16]rx fifo level. Any clock frequency,
//   default 1 MHz SCLK at 100 MHz. Version 1.0.0. Clock - single clock
//   aclk, every input is synchronous to it unless a two-flop synchronizer
//   is mentioned. Reset - synchronous active low aresetn, registers take
//   the documented reset values. Latency - AXI-Lite write response and
//   read data follow the request by about 2 to 3 clocks (ip_axil_regs,
//   registered read path). Timing - registered outputs, no combinational
//   path from the bus to the pins. Errors - out of range AXI-Lite accesses
//   return SLVERR; illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-09-29

module spi_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCLK_HZ    = 1_000_000,     // default SCLK frequency
  parameter int DATA_W     = 32,            // max bits per word
  parameter int NUM_CS     = 4,
  parameter int FIFO_DEPTH = 512
) (
  input  logic               aclk,
  input  logic               aresetn,
  // AXI4-Lite slave
  input  logic [7:0]         s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [7:0]         s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  // AXI4-Stream slave: words to send (MOSI)
  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  // AXI4-Stream master: words received (MISO)
  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  // SPI pins
  output logic               spi_sclk_o,
  output logic               spi_mosi_o,
  input  logic               spi_miso_i,
  output logic [NUM_CS-1:0]  spi_cs_n_o
);
