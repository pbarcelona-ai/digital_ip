// ***************
// Filename: uart_top.sv
// Author: FPGA Cores 4 U
// Description: UART IP top level. Full duplex UART with a fractional baud
//   generator, transmit and receive FIFOs (block RAM for deep FIFOs) and
//   AXI-Stream data ports: s_axis carries bytes to transmit, m_axis
//   carries received bytes. Control and status through AXI-Lite. Map -
//   0x00 CTRL [0]tx_en [1]rx_en [2]par_en [3]par_odd [4]stop2 [5]loopback
//   [7:6]bits(0=8,1=7,2=6,3=5); 0x04 FCW; 0x08 STATUS [0]tx_busy
//   [1]rx_busy [2]rx_avail [8]frame_err [9]parity_err [10]overrun (W1C)
//   [30:16]rx level; 0x0C error frame count. Version 1.0.0. Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29

module uart_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 115_200,    // default baud rate
  parameter int FIFO_DEPTH = 512         // power of two
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
  // AXI4-Stream slave: bytes to transmit
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: received bytes
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Serial pins
  output logic        uart_txd_o,
  input  logic        uart_rxd_i
);
