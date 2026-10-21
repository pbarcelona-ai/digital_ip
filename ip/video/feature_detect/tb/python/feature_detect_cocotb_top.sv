// ***************
// Filename: feature_detect_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of feature_detect_top (the logic with its
//   AXI4-Lite register map) for the comparison with its model
//   (feature_detect_tb.py): the register bus as flattened axi_* ports
//   (ADDR_W 8), the observed stream as s_* inputs (the test drives tvalid
//   and tready), the forwarded beats as m_* outputs with feat_o and
//   done_o. Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module feature_detect_cocotb_top #(
  parameter int MAXW      = 256,
  parameter int MAXH      = 128,
  parameter int CELL_LOG2 = 2,
  parameter int SHIFT_MAX = 4
) (
  input  logic        clk,
  input  logic        rst_n,
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
  input  logic        axi_rready,
  input  logic [23:0] s_tdata,
  input  logic        s_tvalid,
  input  logic        s_tready,
  input  logic        s_tlast,
  input  logic        s_tuser,
  output logic [23:0] m_tdata,
  output logic        m_tvalid,
  output logic        m_tlast,
  output logic        m_tuser,
  output logic [1:0]  feat_o,
  output logic        done_o
);
  axil_if #(.ADDR_W(8)) bus ();
  axis_if #(.DATA_W(24)) si ();
  axis_if #(.DATA_W(24)) mi ();
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
  assign si.tdata = s_tdata;
  assign si.tvalid = s_tvalid;
  assign si.tready = s_tready;
  assign si.tlast = s_tlast;
  assign si.tuser = s_tuser;
  assign si.tkeep = '1;
  assign m_tdata = mi.tdata;
  assign m_tvalid = mi.tvalid;
  assign mi.tready = 1'b1;
  assign m_tlast = mi.tlast;
  assign m_tuser = mi.tuser;
  feature_detect_top #(
    .MAXW(MAXW),
    .MAXH(MAXH),
    .CELL_LOG2(CELL_LOG2),
    .SHIFT_MAX(SHIFT_MAX)
  ) u_top (
    .clk,
    .rst_n,
    .s_axil(bus),
    .s_axis(si),
    .m_axis(mi),
    .feat_o,
    .done_o
  );
  wire unused_ok = &{1'b0, mi.tkeep, 1'b0};
endmodule
