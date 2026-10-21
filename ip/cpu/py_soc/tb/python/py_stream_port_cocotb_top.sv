// ***************
// Filename: py_stream_port_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of py_stream_port (py_stream_port_tb.py compares
//   it with the golden model ip/cpu/py_soc/model/py_stream_port_model.py). Two
//   independent instances on one clock: u_core, the logic with its register
//   interface and streams on ports (core_*, ptx_* the TX stream to the
//   peripheral, prx_* the RX stream from it), and u_top, py_stream_port_top
//   with its AXI4-Lite register map (axi_* ports, ADDR_W 8; TX taken at once,
//   no RX words). Clock - aclk. Reset - synchronous active low aresetn.
// Date: 2026-10-20
// ***************
module py_stream_port_cocotb_top #(
  parameter int DATA_W   = 8,
  parameter int TX_DEPTH = 16,
  parameter int RX_DEPTH = 16
) (
  input  logic              aclk,
  input  logic              aresetn,
  // u_core: register interface
  input  logic [24:0]       core_txdata,
  input  logic              core_txdata_wr,
  input  logic              core_rxdata_rd,
  input  logic [31:0]       core_status,
  input  logic              core_status_wr,
  input  logic [2:0]        core_irq_en,
  output logic [31:0]       core_sts_rxdata,
  output logic [31:0]       core_sts_status,
  output logic              core_irq_o,
  // u_core: streams
  output logic [DATA_W-1:0] ptx_tdata,
  output logic              ptx_tlast,
  output logic              ptx_tvalid,
  input  logic              ptx_tready,
  input  logic [DATA_W-1:0] prx_tdata,
  input  logic              prx_tlast,
  input  logic              prx_tvalid,
  output logic              prx_tready,
  // u_top
  output logic              top_irq_o,
  input  logic [7:0]        axi_awaddr,
  input  logic              axi_awvalid,
  output logic              axi_awready,
  input  logic [31:0]       axi_wdata,
  input  logic [3:0]        axi_wstrb,
  input  logic              axi_wvalid,
  output logic              axi_wready,
  output logic [1:0]        axi_bresp,
  output logic              axi_bvalid,
  input  logic              axi_bready,
  input  logic [7:0]        axi_araddr,
  input  logic              axi_arvalid,
  output logic              axi_arready,
  output logic [31:0]       axi_rdata,
  output logic [1:0]        axi_rresp,
  output logic              axi_rvalid,
  input  logic              axi_rready
);
  // ---------------- the logic ----------------
  py_stream_port_regs_if u_regs_if ();
  assign u_regs_if.cfg_txdata = core_txdata;
  assign u_regs_if.cfg_txdata_wr = core_txdata_wr;
  assign u_regs_if.cfg_rxdata_rd = core_rxdata_rd;
  assign u_regs_if.cfg_status = core_status;
  assign u_regs_if.cfg_status_wr = core_status_wr;
  assign u_regs_if.cfg_irq_en = core_irq_en;
  assign u_regs_if.cfg_irq_en_wr = 1'b0;                      // acts by value
  assign core_sts_rxdata = u_regs_if.sts_rxdata;
  assign core_sts_status = u_regs_if.sts_status;

  axis_if #(.DATA_W(DATA_W)) m_axis ();
  axis_if #(.DATA_W(DATA_W)) s_axis ();
  assign ptx_tdata = m_axis.tdata;
  assign ptx_tlast = m_axis.tlast;
  assign ptx_tvalid = m_axis.tvalid;
  assign m_axis.tready = ptx_tready;
  assign s_axis.tdata = prx_tdata;
  assign s_axis.tlast = prx_tlast;
  assign s_axis.tvalid = prx_tvalid;
  assign s_axis.tkeep = '1;
  assign s_axis.tuser = '0;
  assign prx_tready = s_axis.tready;

  py_stream_port #(.DATA_W(DATA_W), .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH)) u_core (
    .aclk,
    .aresetn,
    .m_axis,
    .s_axis,
    .irq_o(core_irq_o),
    .regs(u_regs_if)
  );

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(DATA_W)) t_m_axis ();
  axis_if #(.DATA_W(DATA_W)) t_s_axis ();
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
  assign t_m_axis.tready = 1'b0;                              // TX words stay (levels readable)
  assign t_s_axis.tdata = '0;
  assign t_s_axis.tlast = 1'b0;
  assign t_s_axis.tvalid = 1'b0;
  assign t_s_axis.tkeep = '1;
  assign t_s_axis.tuser = '0;
  wire unused_ok = &{1'b0, m_axis.tkeep, m_axis.tuser, t_m_axis.tdata, t_m_axis.tlast, t_m_axis.tvalid,
                     t_m_axis.tkeep, t_m_axis.tuser, t_s_axis.tready};

  py_stream_port_top #(.DATA_W(DATA_W), .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .m_axis(t_m_axis),
    .s_axis(t_s_axis),
    .irq_o(top_irq_o)
  );
endmodule
