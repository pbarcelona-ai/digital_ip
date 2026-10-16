// ***************
// Filename: usb_fs_sie_top.sv
// Author: FPGA Cores 4 U
// Description: USB 1.1 full-speed serial interface engine IP. Bit-level D+/D-
//   interface (NRZI, bit stuffing, SYNC, EOP, CRC5/CRC16, PID check, bus
//   reset detect) with AXI-Stream packet ports. m_axis delivers each received
//   packet as PID (low nibble), payload bytes (CRC16 removed), tlast on the
//   last byte and tuser=1 for packets with errors. s_axis takes packets to
//   send - byte 0 is the PID nibble, then payload; a complete packet must be
//   written before it is transmitted. No enumeration, endpoint or protocol
//   layer is included. AXI-Lite map - 0x00 CTRL [0]enable [1]D+ pull-up; 0x04
//   STATUS [0]bus_reset(W1C) [1]rx_overflow(W1C) [2]tx_busy [3]rx_active
//   [9:8]line D+/D-; 0x08 RX_GOOD; 0x0C RX_BAD; 0x10 TX_PKTS; 0x14 BIT_PERIOD
//   (8.8 clocks). Version 1.0.0. Scope - serial interface engine only (no
//   enumeration, endpoints or protocol stack). Clock - aclk, verified in
//   simulation at 48, 60 and 100 MHz only (BIT_PERIOD is an 8.8 fixed point
//   clocks-per-bit value; other frequencies are untested). Reset -
//   synchronous aresetn, D+/D- released, pull-up off, FIFOs empty. Latency -
//   a packet is sent a few bit times after it is complete in the transmit
//   FIFO, and a received packet appears on m_axis after the EOP and CRC
//   check. Errors - tuser on bad packets (CRC, PID check, stuff error),
//   RX_BAD counter, rx_overflow flag, bus_reset flag; illegal parameters stop
//   elaboration.
// Date: 2026-09-29

module usb_fs_sie_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int FIFO_DEPTH = 512
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
  // AXI4-Stream slave: packets to transmit
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: received packets
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  output logic        m_axis_tuser,
  // USB pins (full speed device / host style)
  input  logic        usb_dp_i,
  input  logic        usb_dm_i,
  output logic        usb_dp_o,
  output logic        usb_dm_o,
  output logic        usb_oe_o,          // 1 = drive the bus
  output logic        usb_pullup_o       // D+ pull-up control (device)
);
