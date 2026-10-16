// ***************
// Filename: i2c_top.sv
// Author: FPGA Cores 4 U
// Description: I2C master IP top level. AXI-Lite registers start and
//   describe a transaction; write data is taken from an AXI-Stream slave
//   port and read data is returned on an AXI-Stream master port (tlast
//   marks the last byte). Open-drain pins use i/o/t style signals. Map -
//   0x00 CTRL [0]en [1]start(pulse) [2]read [3]no_stop; 0x04 ADDR[6:0];
//   0x08 LEN; 0x0C DIV (phase clocks-1, f_scl = f_clk/(4*(DIV+1))); 0x10
//   STATUS [0]busy [1]done [2]nack [3]arb_lost, [3:1] are write-1-to-
//   clear. Version 1.0.0. Clock - single clock aclk, every input is
//   synchronous to it unless a two-flop synchronizer is mentioned. Reset -
//   synchronous active low aresetn, registers take the documented reset
//   values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29

module i2c_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCL_HZ     = 100_000,      // default bus frequency
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
  // AXI4-Stream slave: bytes to write
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: bytes read
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Open-drain bus (o is always 0, t=1 releases the line)
  input  logic        scl_i,
  output logic        scl_o,
  output logic        scl_t,
  input  logic        sda_i,
  output logic        sda_o,
  output logic        sda_t
);
