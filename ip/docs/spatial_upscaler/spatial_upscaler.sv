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
