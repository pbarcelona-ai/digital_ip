// ***************
// Filename: pwm_top.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel PWM IP. Programmable prescaler and period,
//   edge or center aligned counting, per-channel double-buffered duty
//   (updated at the period boundary), optional complementary outputs with
//   programmable dead time and per-channel output inversion. Map - 0x00
//   CTRL [0]en [1]center [2]complementary, 0x04 PERIOD (counter top), 0x08
//   PRESCALE (clk divide-1), 0x0C DEADTIME clocks, 0x10 INVERT mask,
//   0x14+4*n DUTY[n]. Output pipeline is registered for timing. Version
//   1.0.0. Clock - single clock aclk, every input is synchronous to it
//   unless a two-flop synchronizer is mentioned. Reset - synchronous
//   active low aresetn, registers take the documented reset values.
//   Latency - AXI-Lite write response and read data follow the request by
//   about 2 to 3 clocks (ip_axil_regs, registered read path). Timing -
//   registered outputs, no combinational path from the bus to the pins.
//   Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29

module pwm_top #(
  parameter int CHANNELS = 4
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
  output logic [CHANNELS-1:0] pwm_o,     // main outputs
  output logic [CHANNELS-1:0] pwm_n_o,   // complementary outputs
  output logic                period_pulse_o   // one clock per period start
);
