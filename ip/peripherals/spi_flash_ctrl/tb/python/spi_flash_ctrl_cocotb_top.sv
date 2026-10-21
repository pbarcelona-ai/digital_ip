// ***************
// Filename: spi_flash_ctrl_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of spi_flash_ctrl (spi_flash_ctrl_tb.py compares
//   it with the golden model
//   ip/peripherals/spi_flash_ctrl/model/spi_flash_ctrl_model.py). Two
//   independent instances on one clock: u_core, the logic with its register
//   interface, streams and pins on ports (MISO from the testbench), and
//   u_top, spi_flash_ctrl_top with its AXI4-Lite register map (axi_* ports,
//   ADDR_W 8; streams idle, MISO low). Clock - aclk. Reset - synchronous
//   active low aresetn.
// Date: 2026-10-20
// ***************
module spi_flash_ctrl_cocotb_top (
  input  logic        aclk,
  input  logic        aresetn,
  // u_core: register interface
  input  logic [31:0] core_cmd,
  input  logic        core_cmd_wr,
  input  logic [23:0] core_addr,
  input  logic [15:0] core_len,
  input  logic [15:0] core_clkdiv,
  input  logic [2:0]  core_status,
  input  logic        core_status_wr,
  input  logic        core_irq_en,
  output logic [2:0]  core_sts_status,
  output logic        core_irq_o,
  // u_core: streams and pins
  input  logic [7:0]  tx_tdata,
  input  logic        tx_tvalid,
  output logic        tx_tready,
  output logic [7:0]  rx_tdata,
  output logic        rx_tlast,
  output logic        rx_tvalid,
  input  logic        rx_tready,
  input  logic        miso_i,
  output logic        sclk_o,
  output logic        mosi_o,
  output logic        cs_n_o,
  // u_top
  output logic        top_irq_o,
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
  spi_flash_ctrl_regs_if u_regs_if ();
  assign u_regs_if.cfg_cmd = core_cmd;
  assign u_regs_if.cfg_cmd_wr = core_cmd_wr;
  assign u_regs_if.cfg_addr = core_addr;
  assign u_regs_if.cfg_addr_wr = 1'b0;                        // act by value
  assign u_regs_if.cfg_len = core_len;
  assign u_regs_if.cfg_len_wr = 1'b0;
  assign u_regs_if.cfg_clkdiv = core_clkdiv;
  assign u_regs_if.cfg_clkdiv_wr = 1'b0;
  assign u_regs_if.cfg_status = core_status;
  assign u_regs_if.cfg_status_wr = core_status_wr;
  assign u_regs_if.cfg_irq_en = core_irq_en;
  assign u_regs_if.cfg_irq_en_wr = 1'b0;
  assign core_sts_status = u_regs_if.sts_status;

  axis_if #(.DATA_W(8)) s_axis ();
  axis_if #(.DATA_W(8)) m_axis ();
  spi_if #(.NUM_CS(1)) spi ();
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
  assign sclk_o = spi.sclk;
  assign mosi_o = spi.mosi;
  assign cs_n_o = spi.cs_n[0];
  assign spi.miso = miso_i;

  spi_flash_ctrl u_core (
    .aclk,
    .aresetn,
    .s_axis,
    .m_axis,
    .spi,
    .irq_o(core_irq_o),
    .regs(u_regs_if)
  );
  wire unused_ok = &{1'b0, m_axis.tkeep, m_axis.tuser};

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(8)) t_s_axis ();
  axis_if #(.DATA_W(8)) t_m_axis ();
  spi_if #(.NUM_CS(1)) t_spi ();
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
  assign t_spi.miso = 1'b0;
  wire unused_top = &{1'b0, t_s_axis.tready, t_m_axis.tdata, t_m_axis.tlast, t_m_axis.tvalid, t_m_axis.tkeep,
                      t_m_axis.tuser, t_spi.sclk, t_spi.mosi, t_spi.cs_n};

  spi_flash_ctrl_top u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(t_s_axis),
    .m_axis(t_m_axis),
    .spi(t_spi),
    .irq_o(top_irq_o)
  );
endmodule
