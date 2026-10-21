// ***************
// Filename: i2c_master_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of i2c_master (tb/python/i2c_master_tb.py
//   compares it with the golden model
//   ip/peripherals/i2c_master/model/i2c_master_model.py). Two independent
//   instances on one clock:
//     u_core  the logic i2c_master with its register interface on ports
//             (core_*), its write / read AXI-Stream ports (tx_*, rx_*) and
//             the I2C bus resolved here as open-drain wires with pull-ups:
//             scl_line / sda_line = released by the master and not pulled by
//             the testbench's target (tgt_scl_low / tgt_sda_low);
//     u_top   i2c_top, the block with its AXI4-Lite register map (axi_*
//             ports, ADDR_W 8), streams idle, bus released (no target).
//   Clock - aclk. Reset - synchronous active low aresetn (both instances).
// Date: 2026-10-20
// ***************
module i2c_master_cocotb_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCL_HZ     = 100_000,
  parameter int FIFO_DEPTH = 16
) (
  input  logic        aclk,
  input  logic        aresetn,
  // u_core: register interface
  input  logic [3:0]  core_ctrl,
  input  logic        core_ctrl_wr,
  input  logic [6:0]  core_addr,
  input  logic [15:0] core_len,
  input  logic [15:0] core_div,
  input  logic [31:0] core_status,
  input  logic        core_status_wr,
  input  logic        core_irq_en,
  output logic [3:0]  core_sts_ctrl,
  output logic [31:0] core_sts_status,
  output logic        core_irq_o,
  // u_core: streams
  input  logic [7:0]  tx_tdata,
  input  logic        tx_tvalid,
  output logic        tx_tready,
  output logic [7:0]  rx_tdata,
  output logic        rx_tlast,
  output logic        rx_tvalid,
  input  logic        rx_tready,
  // u_core: the bus and the testbench's target
  input  logic        tgt_scl_low,
  input  logic        tgt_sda_low,
  output logic        scl_line,
  output logic        sda_line,
  // u_top: the block with its AXI4-Lite register map
  output logic        top_irq_o,
  output logic        top_scl,          // u_top's SCL line (bus timing check)
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
  i2c_master_regs_if u_regs_if ();
  assign u_regs_if.cfg_ctrl = core_ctrl;
  assign u_regs_if.cfg_ctrl_wr = core_ctrl_wr;
  assign u_regs_if.cfg_addr = core_addr;
  assign u_regs_if.cfg_addr_wr = 1'b0;                        // act by value
  assign u_regs_if.cfg_len = core_len;
  assign u_regs_if.cfg_len_wr = 1'b0;
  assign u_regs_if.cfg_div = core_div;
  assign u_regs_if.cfg_div_wr = 1'b0;
  assign u_regs_if.cfg_status = core_status;
  assign u_regs_if.cfg_status_wr = core_status_wr;
  assign u_regs_if.cfg_irq_en = core_irq_en;
  assign u_regs_if.cfg_irq_en_wr = 1'b0;
  assign core_sts_ctrl = u_regs_if.sts_ctrl;
  assign core_sts_status = u_regs_if.sts_status;

  axis_if #(.DATA_W(8)) s_axis ();
  axis_if #(.DATA_W(8)) m_axis ();
  i2c_if i2c ();
  assign s_axis.tdata = tx_tdata;
  assign s_axis.tvalid = tx_tvalid;
  assign s_axis.tlast = 1'b0;
  assign s_axis.tkeep = 1'b1;
  assign s_axis.tuser = 1'b0;
  assign tx_tready = s_axis.tready;
  assign rx_tdata = m_axis.tdata;
  assign rx_tlast = m_axis.tlast;
  assign rx_tvalid = m_axis.tvalid;
  assign m_axis.tready = rx_tready;
  assign scl_line = (i2c.scl_t | i2c.scl_o) & ~tgt_scl_low;   // open drain, pull-up
  assign sda_line = (i2c.sda_t | i2c.sda_o) & ~tgt_sda_low;
  assign i2c.scl_i = scl_line;
  assign i2c.sda_i = sda_line;

  i2c_master #(
    .CLK_HZ(CLK_HZ),
    .SCL_HZ(SCL_HZ),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_core (
    .aclk,
    .aresetn,
    .s_axis,
    .m_axis,
    .i2c,
    .regs(u_regs_if),
    .irq_o(core_irq_o)
  );

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(8)) t_s_axis ();
  axis_if #(.DATA_W(8)) t_m_axis ();
  i2c_if t_i2c ();
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
  assign t_s_axis.tdata = '0;
  assign t_s_axis.tvalid = 1'b0;
  assign t_s_axis.tlast = 1'b0;
  assign t_s_axis.tkeep = 1'b1;
  assign t_s_axis.tuser = 1'b0;
  assign t_m_axis.tready = 1'b1;
  assign t_i2c.scl_i = t_i2c.scl_t | t_i2c.scl_o;
  assign t_i2c.sda_i = t_i2c.sda_t | t_i2c.sda_o;
  assign top_scl = t_i2c.scl_i;

  i2c_top #(
    .CLK_HZ(CLK_HZ),
    .SCL_HZ(SCL_HZ),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(t_s_axis),
    .m_axis(t_m_axis),
    .i2c(t_i2c),
    .irq_o(top_irq_o)
  );
endmodule
