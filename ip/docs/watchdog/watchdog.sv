// ***************
// Filename: watchdog_top.sv
// Author: FPGA Cores 4 U
// Description: Watchdog timer IP. Prescaled up-counter with programmable
//   timeout and pre-timeout interrupt, optional window mode (kicks before
//   WINDOW_OPEN are violations), key-protected kick register, write-once
//   lock bit that prevents disabling, and a stretched system reset output.
//   Map - 0x00 CTRL [0]en [1]window_en [2]lock, 0x04 TIMEOUT ticks, 0x08
//   PRESCALE (clk divide-1), 0x0C PRETIMEOUT ticks, 0x10 WINDOW_OPEN
//   ticks, 0x14 KICK (write 0x5AFEC0DE), 0x18 STATUS [0]pretimeout
//   [1]expired [2]early kick [3]bad key (W1C), 0x1C COUNT. Version 1.0.0.
//   Clock - single clock aclk, every input is synchronous to it unless a
//   two-flop synchronizer is mentioned. Reset - synchronous active low
//   aresetn, registers take the documented reset values. Latency - AXI-
//   Lite write response and read data follow the request by about 2 to 3
//   clocks (ip_axil_regs, registered read path). Timing - registered
//   outputs, no combinational path from the bus to the pins. Errors - out
//   of range AXI-Lite accesses return SLVERR; illegal parameter values
//   stop elaboration with an $error.
// Date: 2026-09-29

module watchdog_top #(
  parameter int RESET_CYCLES = 16        // width of the reset pulse in clocks
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
  output logic irq_o,                    // pre-timeout interrupt
  output logic wdt_reset_o               // system reset request (active high)
);
