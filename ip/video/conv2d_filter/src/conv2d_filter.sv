// ***************
// Filename: conv2d_filter.sv
// Author: FPGA Cores 4 U
// Description: Programmable N x N convolution filter, the logic of
//   conv2d_filter_top, blur_filter_top and sharpen_filter_top (each with its
//   own register map, ID "C2DF" / "BLRF" / "SHRF"): conv2d_core with the
//   frame size, shift and kernel copied from the register map at each frame
//   start (the core then holds them for the
//   frame; the new frame size reaches isp_window with the start-of-frame
//   pixel, while it waits between frames, so not through s_axis_tready),
//   and the count of frames filtered. Register ports: cfg_frame_size,
//   cfg_shift, cfg_k (FRAME_SIZE, SHIFT, K[i]); sts_status (STATUS, [15:0]
//   frames filtered), sts_info (INFO). Clock - clk. Reset - synchronous rst_n (active low).
// Date: 2026-10-11
module conv2d_filter #(
  parameter int N      = 5,                      // kernel size: 3 or 5
  parameter int C      = 3,                      // components per pixel
  parameter int CW     = 8,                      // bits per component
  parameter int COEF_W = 12,                     // coefficient width
  parameter int MAX_W  = 2048,                   // longest line
  parameter int BORDER = 0                       // 0 clamp to edge, 1 mirror
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [31:0]            cfg_frame_size, // FRAME_SIZE: [15:0] width [31:16] height
  input  logic [4:0]             cfg_shift,      // SHIFT
  input  logic [N*N*COEF_W-1:0]  cfg_k,          // K[i], i = r*N + c
  output logic [31:0]            sts_status,     // STATUS: [15:0] frames filtered
  output logic [31:0]            sts_info,       // INFO: [3:0] N [11:8] COEF_W [23:16] C [31:24] CW
  input  logic [C*CW-1:0]        s_axis_tdata,
  input  logic                   s_axis_tlast,
  input  logic                   s_axis_tuser,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  output logic [C*CW-1:0]        m_axis_tdata,
  output logic                   m_axis_tlast,
  output logic                   m_axis_tuser,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready
);
  localparam int NN = N * N;
  logic [NN*COEF_W-1:0] coef_f;
  logic [4:0] shift_f;
  logic [31:0] size_f;
  logic sof_wait, frame;
  wire        sof_in = s_axis_tvalid && s_axis_tready && s_axis_tuser;
  wire [31:0] size   = (sof_wait && s_axis_tvalid && s_axis_tuser) ? cfg_frame_size : size_f;
  always_ff @(posedge clk) begin
    if (!rst_n || sof_in) begin
      coef_f  <= cfg_k;
      shift_f <= cfg_shift;
      size_f  <= cfg_frame_size;
    end
  end
  conv2d_core #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_core (
    .clk,
    .rst_n,
    .width_i(size[15:0]),
    .height_i(size[31:16]),
    .coef_i(coef_f),
    .shift_i(shift_f),
    .s_axis_tdata,
    .s_axis_tlast,
    .s_axis_tuser,
    .s_axis_tvalid,
    .s_axis_tready,
    .m_axis_tdata,
    .m_axis_tlast,
    .m_axis_tuser,
    .m_axis_tvalid,
    .m_axis_tready,
    .frame_o(frame),
    .sof_wait_o(sof_wait)
  );
  logic [15:0] frames;
  always_ff @(posedge clk)
    if (!rst_n) frames <= '0;
    else if (frame) frames <= frames + 1'b1;
  assign sts_status = {16'd0, frames};
  assign sts_info = {8'(CW), 8'(C), 4'd0, 4'(COEF_W), 4'd0, 4'(N)};
endmodule
