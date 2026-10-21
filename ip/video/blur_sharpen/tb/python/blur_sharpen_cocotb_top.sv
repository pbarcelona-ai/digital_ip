// ***************
// Filename: blur_sharpen_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of blur_sharpen_top (the filter pair with its
//   AXI4-Lite register map) for the comparison with its model
//   (blur_sharpen_tb.py): the register bus as flattened axi_* ports
//   (ADDR_W 9), the input stream as s_* ports, the output as m_* ports.
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module blur_sharpen_cocotb_top #(
  parameter int N      = 5,
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 64,
  parameter int BORDER = 0,
  parameter int AMOUNT = 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [8:0]  axi_awaddr,
  input  logic        axi_awvalid,
  output logic        axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0]  axi_wstrb,
  input  logic        axi_wvalid,
  output logic        axi_wready,
  output logic [1:0]  axi_bresp,
  output logic        axi_bvalid,
  input  logic        axi_bready,
  input  logic [8:0]  axi_araddr,
  input  logic        axi_arvalid,
  output logic        axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0]  axi_rresp,
  output logic        axi_rvalid,
  input  logic        axi_rready,
  input  logic [C*CW-1:0] s_tdata,
  input  logic        s_tvalid,
  output logic        s_tready,
  input  logic        s_tlast,
  input  logic        s_tuser,
  output logic [C*CW-1:0] m_tdata,
  output logic        m_tvalid,
  input  logic        m_tready,
  output logic        m_tlast,
  output logic        m_tuser
);
  axil_if #(.ADDR_W(9)) bus ();
  axis_if #(.DATA_W(C*CW)) si ();
  axis_if #(.DATA_W(C*CW)) mi ();
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
  assign s_tready = si.tready;
  assign si.tlast = s_tlast;
  assign si.tuser = s_tuser;
  assign si.tkeep = '1;
  assign m_tdata = mi.tdata;
  assign m_tvalid = mi.tvalid;
  assign mi.tready = m_tready;
  assign m_tlast = mi.tlast;
  assign m_tuser = mi.tuser;
  blur_sharpen_top #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER),
    .AMOUNT(AMOUNT),
    .RESET_W(16'd16),
    .RESET_H(16'd8)
  ) u_top (
    .clk,
    .rst_n,
    .s_axil(bus),
    .s_axis(si),
    .m_axis(mi)
  );
  wire unused_ok = &{1'b0, si.tkeep, mi.tkeep, 1'b0};
endmodule
