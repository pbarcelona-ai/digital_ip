// ***************
// Filename: ip_reset_sync_top.sv
// Author: FPGA Cores 4 U
// Description: Top level of the reset synchronizer IP. Synchronizes an
//   asynchronous external reset for the AXI-Lite bus and for NUM_OUT
//   replicated user resets (fan-out control). A software reset bit, hold-time
//   register, reset event counter and status are exposed through an AXI-Lite
//   register file. The register map
//   reset_ctrl_regs (u_regs, src/include/reset_ctrl_regs.sv: ID "RSTC" /
//   VERSION / DATE at 0x00-0x08, 0x10 CTRL[0]=soft reset (self clearing),
//   0x14 HOLD cycles, 0x18 STATUS[0]=active [1]=event seen (W1C), 0x1C event
//   count) is reset by the synchronized bus reset of the logic reset_ctrl
//   (u_core, src/reset_ctrl.sv). Hand-written wrapper (regmap_gen "top":
//   false) because of that internal bus reset. Version 1.0.0. Clock - aclk, the external reset arst_i is
//   asynchronous and is synchronized with STAGES flops. Reset - the reset
//   asserts asynchronously and releases synchronously; outputs are held for
//   HOLD_DEFAULT clocks or the programmed hold. Latency - release is STAGES+1
//   clocks after arst_i deasserts plus the hold. Errors - illegal parameters
//   stop elaboration; out of range AXI-Lite accesses return SLVERR.
// Date: 2026-10-12
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
  logic        cfg_ctrl, cfg_ctrl_wr, cfg_status_wr;
  logic [15:0] cfg_hold;
  logic [1:0]  cfg_status, sts_status;
  logic [31:0] sts_event_count;
  reset_ctrl_regs #(
    .HOLD_RST(HOLD_DEFAULT)
  ) u_regs (
    .aclk,
    .aresetn(bus_rst_n_o),
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .ctrl_o(cfg_ctrl),
    .ctrl_wr_o(cfg_ctrl_wr),
    .hold_o(cfg_hold),
    .hold_wr_o(),
    .status_i(sts_status),
    .status_o(cfg_status),
    .status_wr_o(cfg_status_wr),
    .event_count_i(sts_event_count)
  );
  reset_ctrl #(
    .STAGES(STAGES),
    .NUM_OUT(NUM_OUT),
    .ACTIVE_LOW_IN(ACTIVE_LOW_IN),
    .ACTIVE_LOW_OUT(ACTIVE_LOW_OUT),
    .HOLD_DEFAULT(HOLD_DEFAULT)
  ) u_core (
    .aclk,
    .arst_i,
    .rst_o,
    .bus_rst_n_o,
    .cfg_ctrl,
    .cfg_ctrl_wr,
    .cfg_hold,
    .cfg_status,
    .cfg_status_wr,
    .sts_status,
    .sts_event_count
  );
endmodule
