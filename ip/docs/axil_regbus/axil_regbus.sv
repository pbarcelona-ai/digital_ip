// ***************
// Filename: axil_regbus.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite slave to register bus bridge.
//   Converts AXI4-Lite transactions into a simple one-cycle register bus.
//   Write: reg_wr pulses for one clock with reg_waddr/reg_wdata/reg_wstrb
//   once both the AW and W beats have arrived (in either order); the B
//   response (always OKAY) is raised in the same cycle.
//   Read: reg_rd pulses for one clock with reg_raddr. The register block
//   must return reg_rdata on the following cycle (registered read); the
//   data is then captured and presented on the R channel (always OKAY).
//   One outstanding write and one outstanding read are supported. R and B
//   data stay stable while the master stalls ready.
// Date: 2026-09-26

module axil_regbus #(
  // ADDR_W : AXI address width in bits
  // DATA_W : AXI data width in bits (register width)
  parameter int ADDR_W = 16,
  parameter int DATA_W = 32
)(
  input  logic                clk,            // clock
  input  logic                rst_n,          // async reset, active low
  // AXI4-Lite slave: AW/W/B write channels, AR/R read channels
  input  logic [ADDR_W-1:0]   s_axil_awaddr,
  input  logic                s_axil_awvalid,
  output logic                s_axil_awready,
  input  logic [DATA_W-1:0]   s_axil_wdata,
  input  logic [DATA_W/8-1:0] s_axil_wstrb,
  input  logic                s_axil_wvalid,
  output logic                s_axil_wready,
  output logic [1:0]          s_axil_bresp,
  output logic                s_axil_bvalid,
  input  logic                s_axil_bready,
  input  logic [ADDR_W-1:0]   s_axil_araddr,
  input  logic                s_axil_arvalid,
  output logic                s_axil_arready,
  output logic [DATA_W-1:0]   s_axil_rdata,
  output logic [1:0]          s_axil_rresp,
  output logic                s_axil_rvalid,
  input  logic                s_axil_rready,
  // Simple register bus towards the register block
  output logic                reg_wr,
  output logic [ADDR_W-1:0]   reg_waddr,
  output logic [DATA_W-1:0]   reg_wdata,
  output logic [DATA_W/8-1:0] reg_wstrb,
  output logic                reg_rd,
  output logic [ADDR_W-1:0]   reg_raddr,
  input  logic [DATA_W-1:0]   reg_rdata       // valid 1 cycle after reg_rd
);
