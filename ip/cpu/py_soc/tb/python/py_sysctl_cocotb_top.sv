// ***************
// Filename: py_sysctl_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of py_sysctl (py_sysctl_tb.py compares it with
//   the golden model ip/cpu/py_soc/model/py_sysctl_model.py). Two independent
//   instances on one clock: u_core, the logic with its register interface on
//   ports (core_*), and u_top, py_sysctl_top with its AXI4-Lite register map
//   (axi_* ports, ADDR_W 8). Both: NCLK 4, CLK_EN_RST 0, a clock generator
//   present and locked, boot done, no watchdog reset (py_soc's model).
//   Clock - aclk. Reset - aresetn (system), por_n (external).
// Date: 2026-10-20
// ***************
module py_sysctl_cocotb_top #(
  parameter int NCLK = 4
) (
  input  logic            aclk,
  input  logic            aresetn,
  input  logic            por_n,
  // u_core: register interface
  input  logic [1:0]      core_reset_cause,
  input  logic            core_reset_cause_wr,
  input  logic            core_core_reset,
  input  logic [NCLK-1:0] core_clk_en,
  input  logic [31:0]     core_timer_cmp,
  input  logic            core_timer_cmp_wr,
  input  logic            core_timer_ctrl,
  input  logic            core_timer_status,
  input  logic            core_timer_status_wr,
  output logic [1:0]      core_sts_reset_cause,
  output logic [31:0]     core_sts_boot_status,
  output logic [31:0]     core_sts_cycles,
  output logic [31:0]     core_sts_soc_id,
  output logic [1:0]      core_sts_clk_status,
  output logic            core_sts_timer_status,
  output logic            core_timer_irq_o,
  output logic            core_core_rst_n_o,
  output logic [NCLK-1:0] core_clk_en_o,
  // u_top
  output logic            top_timer_irq_o,
  output logic            top_core_rst_n_o,
  output logic [NCLK-1:0] top_clk_en_o,
  input  logic [7:0]      axi_awaddr,
  input  logic            axi_awvalid,
  output logic            axi_awready,
  input  logic [31:0]     axi_wdata,
  input  logic [3:0]      axi_wstrb,
  input  logic            axi_wvalid,
  output logic            axi_wready,
  output logic [1:0]      axi_bresp,
  output logic            axi_bvalid,
  input  logic            axi_bready,
  input  logic [7:0]      axi_araddr,
  input  logic            axi_arvalid,
  output logic            axi_arready,
  output logic [31:0]     axi_rdata,
  output logic [1:0]      axi_rresp,
  output logic            axi_rvalid,
  input  logic            axi_rready
);
  // ---------------- the logic ----------------
  py_sysctl_regs_if #(.NCLK(NCLK)) u_regs_if ();
  assign u_regs_if.cfg_reset_cause = core_reset_cause;
  assign u_regs_if.cfg_reset_cause_wr = core_reset_cause_wr;
  assign u_regs_if.cfg_core_reset = core_core_reset;
  assign u_regs_if.cfg_core_reset_wr = 1'b0;                  // act by value
  assign u_regs_if.cfg_clk_en = core_clk_en;
  assign u_regs_if.cfg_clk_en_wr = 1'b0;
  assign u_regs_if.cfg_timer_cmp = core_timer_cmp;
  assign u_regs_if.cfg_timer_cmp_wr = core_timer_cmp_wr;
  assign u_regs_if.cfg_timer_ctrl = core_timer_ctrl;
  assign u_regs_if.cfg_timer_ctrl_wr = 1'b0;
  assign u_regs_if.cfg_timer_status = core_timer_status;
  assign u_regs_if.cfg_timer_status_wr = core_timer_status_wr;
  assign core_sts_reset_cause = u_regs_if.sts_reset_cause;
  assign core_sts_boot_status = u_regs_if.sts_boot_status;
  assign core_sts_cycles = u_regs_if.sts_cycles;
  assign core_sts_soc_id = u_regs_if.sts_soc_id;
  assign core_sts_clk_status = u_regs_if.sts_clk_status;
  assign core_sts_timer_status = u_regs_if.sts_timer_status;

  py_sysctl #(.NCLK(NCLK), .CLK_EN_RST({NCLK{1'b0}}), .CLKGEN(1'b1)) u_core (
    .aclk,
    .aresetn,
    .por_n,
    .wdt_reset_i(1'b0),
    .boot_done_i(1'b1),
    .boot_err_i(1'b0),
    .boot_err_code_i(3'd0),
    .core_rst_n_o(core_core_rst_n_o),
    .clk_en_o(core_clk_en_o),
    .clk_locked_i(1'b1),
    .timer_irq_o(core_timer_irq_o),
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

  py_sysctl_top #(.NCLK(NCLK), .CLK_EN_RST({NCLK{1'b0}}), .CLKGEN(1'b1)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .por_n,
    .wdt_reset_i(1'b0),
    .boot_done_i(1'b1),
    .boot_err_i(1'b0),
    .boot_err_code_i(3'd0),
    .core_rst_n_o(top_core_rst_n_o),
    .clk_en_o(top_clk_en_o),
    .clk_locked_i(1'b1),
    .timer_irq_o(top_timer_irq_o)
  );
endmodule
