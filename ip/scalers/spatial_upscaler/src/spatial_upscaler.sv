// ***************
// Filename: spatial_upscaler.sv
// Author: FPGA Cores 4 U
// Description: FSR 1-style spatial upscaler: Lanczos resampling followed by
//   contrast-adaptive sharpening, behind one AXI4-Lite port.
//     s_axis -> scaler_lanczos (any size change) -> sharpen_cas -> m_axis
//   Register map (byte addresses, ADDR_W = 15):
//     0x0000 - 0x3FFF  scaler_lanczos: common scaler map (CTRL, IN_SIZE,
//                      OUT_SIZE, STEP, OFFS, ...), COEF_INFO at 0x040,
//                      H table at 0x1000, V table at 0x2000
//     0x4000 - 0x40FF  sharpen_cas: CTRL 0x4000, STATUS 0x4004,
//                      SIZE 0x4008 (must equal the scaler OUT_SIZE),
//                      FRAME_CNT 0x4020, IP_ID 0x4024, SHARPNESS 0x4040
//   Program the sharpener SIZE and enable it before enabling the scaler.
//   Resource note: the sharpener line buffers are sized for the output
//   width (OUT_MAX_W), the scaler frame buffer for the input (MAX_W x MAX_H).
//   Dependencies: axil_split, axil_regbus, scaler_lanczos, scaler_polyphase,
//                 scaler_ctrl, scaler_dda, banked_framebuf, sharpen_cas
// Date: 2026-09-26

module spatial_upscaler #(
  parameter int CHANNELS  = 3,
  parameter int COMP_W    = 8,
  parameter int MAX_W     = 1280,      // largest input frame
  parameter int MAX_H     = 720,
  parameter int OUT_MAX_W = 2560,      // largest output line
  parameter int ADDR_W    = 15,
  parameter int PINGPONG = 0,          // scaler stage: 1 = double frame buffer
  parameter int LINE_BUF = 0,          // scaler stage: 1 = line buffer (whole chain streams)
  localparam int PIX_W    = CHANNELS * COMP_W
)(
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // AXI4-Stream in
  input  logic [PIX_W-1:0]  s_axis_tdata,
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,
  input  logic              s_axis_tuser,
  input  logic              s_axis_tlast,
  // AXI4-Stream out
  output logic [PIX_W-1:0]  m_axis_tdata,
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,
  output logic              m_axis_tuser,
  output logic              m_axis_tlast
);

  initial if (ADDR_W != 15) $fatal(1, "spatial_upscaler: ADDR_W must be 15");

  // ------------------------------------------------------------ AXI-Lite split
  logic [2*ADDR_W-1:0] m_awaddr, m_araddr;
  logic [1:0]          m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [1:0]          m_arvalid, m_arready, m_rvalid, m_rready;
  logic [63:0]         m_wdata, m_rdata;
  logic [7:0]          m_wstrb;
  logic [3:0]          m_bresp, m_rresp;

  axil_split #(.ADDR_W(ADDR_W), .SEL_BIT(14)) u_split (
    .clk, .rst_n,
    .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
    .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
    .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
    .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
    .m_awaddr, .m_awvalid, .m_awready, .m_wdata, .m_wstrb, .m_wvalid, .m_wready,
    .m_bresp, .m_bvalid, .m_bready, .m_araddr, .m_arvalid, .m_arready,
    .m_rdata, .m_rresp, .m_rvalid, .m_rready);

  // ------------------------------------------------------------ stage 1: Lanczos
  logic [PIX_W-1:0] mid_tdata;
  logic             mid_tvalid, mid_tready, mid_tuser, mid_tlast;

  scaler_lanczos #(.PINGPONG(PINGPONG), .LINE_BUF(LINE_BUF), .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                   .ADDR_W(14)) u_scaler (
    .clk, .rst_n,
    .s_axil_awaddr(m_awaddr[13:0]), .s_axil_awvalid(m_awvalid[0]), .s_axil_awready(m_awready[0]),
    .s_axil_wdata(m_wdata[31:0]), .s_axil_wstrb(m_wstrb[3:0]), .s_axil_wvalid(m_wvalid[0]), .s_axil_wready(m_wready[0]),
    .s_axil_bresp(m_bresp[1:0]), .s_axil_bvalid(m_bvalid[0]), .s_axil_bready(m_bready[0]),
    .s_axil_araddr(m_araddr[13:0]), .s_axil_arvalid(m_arvalid[0]), .s_axil_arready(m_arready[0]),
    .s_axil_rdata(m_rdata[31:0]), .s_axil_rresp(m_rresp[1:0]), .s_axil_rvalid(m_rvalid[0]), .s_axil_rready(m_rready[0]),
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
    .m_axis_tdata(mid_tdata), .m_axis_tvalid(mid_tvalid), .m_axis_tready(mid_tready),
    .m_axis_tuser(mid_tuser), .m_axis_tlast(mid_tlast));

  // ------------------------------------------------------------ stage 2: CAS
  sharpen_cas #(.CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(OUT_MAX_W), .ADDR_W(8)) u_sharpen (
    .clk, .rst_n,
    .s_axil_awaddr(m_awaddr[ADDR_W +: 8]), .s_axil_awvalid(m_awvalid[1]), .s_axil_awready(m_awready[1]),
    .s_axil_wdata(m_wdata[63:32]), .s_axil_wstrb(m_wstrb[7:4]), .s_axil_wvalid(m_wvalid[1]), .s_axil_wready(m_wready[1]),
    .s_axil_bresp(m_bresp[3:2]), .s_axil_bvalid(m_bvalid[1]), .s_axil_bready(m_bready[1]),
    .s_axil_araddr(m_araddr[ADDR_W +: 8]), .s_axil_arvalid(m_arvalid[1]), .s_axil_arready(m_arready[1]),
    .s_axil_rdata(m_rdata[63:32]), .s_axil_rresp(m_rresp[3:2]), .s_axil_rvalid(m_rvalid[1]), .s_axil_rready(m_rready[1]),
    .s_axis_tdata(mid_tdata), .s_axis_tvalid(mid_tvalid), .s_axis_tready(mid_tready),
    .s_axis_tuser(mid_tuser), .s_axis_tlast(mid_tlast),
    .m_axis_tdata, .m_axis_tvalid, .m_axis_tready, .m_axis_tuser, .m_axis_tlast);

endmodule
