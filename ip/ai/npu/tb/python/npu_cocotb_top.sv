// ***************
// Filename: npu_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of npu_top: the AXI4-Lite register bus as
//   flattened axi_* ports (ADDR_W 8), the video tap as v_* ports, the AXI4 master and irq_o as they are
//   (the tests put a byte-array memory behind them).
// Date: 2026-10-25
module npu_cocotb_top #(
  parameter int PE_P = 8,
  parameter int PE_O = 8
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [23:0] v_tdata,
  input  logic v_tvalid,
  input  logic v_tready,
  input  logic v_tlast,
  input  logic v_tuser,
  input  logic [7:0] axi_awaddr,
  input  logic axi_awvalid,
  output logic axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0] axi_wstrb,
  input  logic axi_wvalid,
  output logic axi_wready,
  output logic [1:0] axi_bresp,
  output logic axi_bvalid,
  input  logic axi_bready,
  input  logic [7:0] axi_araddr,
  input  logic axi_arvalid,
  output logic axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0] axi_rresp,
  output logic axi_rvalid,
  input  logic axi_rready,
  output logic [3:0] m_axi_awid,
  output logic [31:0] m_axi_awaddr,
  output logic [7:0] m_axi_awlen,
  output logic [2:0] m_axi_awsize,
  output logic [1:0] m_axi_awburst,
  output logic m_axi_awvalid,
  input  logic m_axi_awready,
  output logic [255:0] m_axi_wdata,
  output logic [31:0] m_axi_wstrb,
  output logic m_axi_wlast,
  output logic m_axi_wvalid,
  input  logic m_axi_wready,
  input  logic [3:0] m_axi_bid,
  input  logic [1:0] m_axi_bresp,
  input  logic m_axi_bvalid,
  output logic m_axi_bready,
  output logic [3:0] m_axi_arid,
  output logic [31:0] m_axi_araddr,
  output logic [7:0] m_axi_arlen,
  output logic [2:0] m_axi_arsize,
  output logic [1:0] m_axi_arburst,
  output logic m_axi_arvalid,
  input  logic m_axi_arready,
  input  logic [3:0] m_axi_rid,
  input  logic [255:0] m_axi_rdata,
  input  logic [1:0] m_axi_rresp,
  input  logic m_axi_rlast,
  input  logic m_axi_rvalid,
  output logic m_axi_rready,
  output logic irq_o,
  output logic run_done_o,
  output logic auto_o
);
  axil_if #(.ADDR_W(8)) bus ();
  axis_if #(.DATA_W(24)) vid ();
  assign vid.tdata = v_tdata;
  assign vid.tvalid = v_tvalid;
  assign vid.tready = v_tready;
  assign vid.tlast = v_tlast;
  assign vid.tuser = v_tuser;
  assign vid.tkeep = '1;
  assign bus.awaddr = axi_awaddr;
  assign bus.awvalid = axi_awvalid;
  assign axi_awready = bus.awready;
  assign bus.wdata = axi_wdata;
  assign bus.wstrb = axi_wstrb;
  assign bus.wvalid = axi_wvalid;
  assign axi_wready = bus.wready;
  assign axi_bresp = bus.bresp;
  assign axi_bvalid = bus.bvalid;
  assign bus.bready = axi_bready;
  assign bus.araddr = axi_araddr;
  assign bus.arvalid = axi_arvalid;
  assign axi_arready = bus.arready;
  assign axi_rdata = bus.rdata;
  assign axi_rresp = bus.rresp;
  assign axi_rvalid = bus.rvalid;
  assign bus.rready = axi_rready;
  npu_top #(
    .PE_P(PE_P),
    .PE_O(PE_O)
  ) u_npu (
    .clk,
    .rst_n,
    .s_axil(bus),
    .irq_o,
    .run_done_o,
    .auto_o,
    .s_axis(vid),
    .m_axi_awid,
    .m_axi_awaddr,
    .m_axi_awlen,
    .m_axi_awsize,
    .m_axi_awburst,
    .m_axi_awvalid,
    .m_axi_awready,
    .m_axi_wdata,
    .m_axi_wstrb,
    .m_axi_wlast,
    .m_axi_wvalid,
    .m_axi_wready,
    .m_axi_bid,
    .m_axi_bresp,
    .m_axi_bvalid,
    .m_axi_bready,
    .m_axi_arid,
    .m_axi_araddr,
    .m_axi_arlen,
    .m_axi_arsize,
    .m_axi_arburst,
    .m_axi_arvalid,
    .m_axi_arready,
    .m_axi_rid,
    .m_axi_rdata,
    .m_axi_rresp,
    .m_axi_rlast,
    .m_axi_rvalid,
    .m_axi_rready
  );
endmodule
