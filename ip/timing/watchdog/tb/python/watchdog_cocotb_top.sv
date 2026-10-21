// ***************
// Filename: watchdog_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of watchdog (watchdog_tb.py compares it with the
//   golden model ip/timing/watchdog/model/watchdog_model.py). Two independent
//   instances on one clock: u_core, the logic with its register interface on
//   ports (core_*), and u_top, watchdog_top with its AXI4-Lite register map
//   (axi_* ports, ADDR_W 8). Clock - aclk. Reset - synchronous active low
//   aresetn.
// Date: 2026-10-20
// ***************
module watchdog_cocotb_top #(
  parameter int RESET_CYCLES = 16
) (
  input  logic        aclk,
  input  logic        aresetn,
  // u_core: register interface
  input  logic [2:0]  core_ctrl,
  input  logic        core_ctrl_wr,
  input  logic [31:0] core_timeout,
  input  logic [31:0] core_prescale,
  input  logic [31:0] core_pretimeout,
  input  logic [31:0] core_window_open,
  input  logic [31:0] core_kick,
  input  logic        core_kick_wr,
  input  logic [3:0]  core_status,
  input  logic        core_status_wr,
  output logic [2:0]  core_sts_ctrl,
  output logic [3:0]  core_sts_status,
  output logic [31:0] core_sts_count,
  output logic        core_irq_o,
  output logic        core_wdt_reset_o,
  // u_top
  output logic        top_irq_o,
  output logic        top_wdt_reset_o,
  input  logic [7:0]  axi_awaddr,
  input  logic        axi_awvalid,
  output logic        axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0]  axi_wstrb,
  input  logic        axi_wvalid,
  output logic        axi_wready,
  output logic [1:0]  axi_bresp,
  output logic        axi_bvalid,
  input  logic        axi_bready,
  input  logic [7:0]  axi_araddr,
  input  logic        axi_arvalid,
  output logic        axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0]  axi_rresp,
  output logic        axi_rvalid,
  input  logic        axi_rready
);
  // ---------------- the logic ----------------
  watchdog_regs_if u_regs_if ();
  assign u_regs_if.cfg_ctrl = core_ctrl;
  assign u_regs_if.cfg_ctrl_wr = core_ctrl_wr;
  assign u_regs_if.cfg_timeout = core_timeout;
  assign u_regs_if.cfg_timeout_wr = 1'b0;                     // act by value
  assign u_regs_if.cfg_prescale = core_prescale;
  assign u_regs_if.cfg_prescale_wr = 1'b0;
  assign u_regs_if.cfg_pretimeout = core_pretimeout;
  assign u_regs_if.cfg_pretimeout_wr = 1'b0;
  assign u_regs_if.cfg_window_open = core_window_open;
  assign u_regs_if.cfg_window_open_wr = 1'b0;
  assign u_regs_if.cfg_kick = core_kick;
  assign u_regs_if.cfg_kick_wr = core_kick_wr;
  assign u_regs_if.cfg_status = core_status;
  assign u_regs_if.cfg_status_wr = core_status_wr;
  assign core_sts_ctrl = u_regs_if.sts_ctrl;
  assign core_sts_status = u_regs_if.sts_status;
  assign core_sts_count = u_regs_if.sts_count;

  watchdog #(.RESET_CYCLES(RESET_CYCLES)) u_core (
    .aclk,
    .aresetn,
    .irq_o(core_irq_o),
    .wdt_reset_o(core_wdt_reset_o),
    .regs(u_regs_if)
  );

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  assign s_axil.awaddr = axi_awaddr;
  assign s_axil.awvalid = axi_awvalid;
  assign axi_awready = s_axil.awready;
  assign s_axil.wdata = axi_wdata;
  assign s_axil.wstrb = axi_wstrb;
  assign s_axil.wvalid = axi_wvalid;
  assign axi_wready = s_axil.wready;
  assign axi_bresp = s_axil.bresp;
  assign axi_bvalid = s_axil.bvalid;
  assign s_axil.bready = axi_bready;
  assign s_axil.araddr = axi_araddr;
  assign s_axil.arvalid = axi_arvalid;
  assign axi_arready = s_axil.arready;
  assign axi_rdata = s_axil.rdata;
  assign axi_rresp = s_axil.rresp;
  assign axi_rvalid = s_axil.rvalid;
  assign s_axil.rready = axi_rready;

  watchdog_top #(.RESET_CYCLES(RESET_CYCLES)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .irq_o(top_irq_o),
    .wdt_reset_o(top_wdt_reset_o)
  );
endmodule
