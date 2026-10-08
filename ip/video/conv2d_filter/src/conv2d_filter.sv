// ***************
// Filename: conv2d_filter.sv
// Author: FPGA Cores 4 U
// Description: Programmable N x N convolution filter: conv2d_core with an
//   AXI4-Lite register map. Version 1.0.0. The kernel defines the filter
//   (blur, sharpen, edge detect, emboss, identity ...); blur_filter and
//   sharpen_filter are this module with other reset kernels.
//   Registers (32-bit, ADDR_W = 8):
//     0x00 ID          RO  ID parameter ("C2DF" by default)
//     0x04 FRAME_SIZE  [15:0] width [31:16] height (>= (N+1)/2 each)
//     0x08 SHIFT       [4:0] result right shift (normalisation)
//     0x0C STATUS      RO  [15:0] frames filtered
//     0x10 INFO        RO  [3:0] N [11:8] COEF_W [23:16] C [31:24] CW
//     0x40 + 4*i K[i]  signed coefficient i = r*N + c (low COEF_W bits
//                      used, reads return the sign-extended value)
//   New FRAME_SIZE / SHIFT / K values are taken at the next frame start
//   (they are copied when a start-of-frame pixel enters, so a frame always
//   uses one complete kernel). out = clamp((sum(K*p) + round) >>> SHIFT).
//   Data - AXI4-Stream video, C components of CW bits, tuser = SOF,
//   tlast = EOL. Clock - clk (stream and registers). Reset - synchronous
//   rst_n (active low). Latency - see conv2d_core.
// Date: 2026-10-08
module conv2d_filter #(
  parameter int N      = 5,
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 2048,
  parameter int BORDER = 0,
  parameter logic [31:0] ID = 32'h4332_4446,                       // "C2DF"
  parameter logic [conv2d_pkg::KMAX*32-1:0] KERNEL = conv2d_pkg::identity_kernel(N),
  parameter int SHIFT  = 0,
  parameter logic [15:0] RESET_W = 16'd1920,
  parameter logic [15:0] RESET_H = 16'd1080
) (
  input  logic               clk,
  input  logic               rst_n,
  // AXI4-Lite
  input  logic [7:0]         s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [7:0]         s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  // Video
  input  logic [C*CW-1:0]    s_axis_tdata,
  input  logic               s_axis_tlast,
  input  logic               s_axis_tuser,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  output logic [C*CW-1:0]    m_axis_tdata,
  output logic               m_axis_tlast,
  output logic               m_axis_tuser,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready
);
  localparam int NN = N * N, KB = 16, NREG = KB + NN;

  function automatic logic [NREG*32-1:0] reset_vals();
    logic [NREG*32-1:0] v; v = '0;
    v[1*32 +: 32] = {RESET_H, RESET_W};
    v[2*32 +: 32] = 32'(SHIFT);
    for (int i = 0; i < NN; i++) v[(KB + i)*32 +: 32] = KERNEL[i*32 +: 32];
    return v;
  endfunction

  logic [NREG*32-1:0] regs, rd;
  ip_axil_regs #(.ADDR_W(8), .NREG(NREG), .RESET_VALS(reset_vals())) u_regs (.aclk(clk), .aresetn(rst_n),
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(), .wr_data_o(), .rd_i(rd));

  // Settings copied at each frame start (the core then holds them for the
  // frame). The new frame size reaches isp_window with the start-of-frame
  // pixel (while it waits between frames, so not through s_axis_tready).
  logic [NN*COEF_W-1:0] coef_f; logic [4:0] shift_f; logic [31:0] size_f; logic sof_wait;
  wire        sof_in = s_axis_tvalid && s_axis_tready && s_axis_tuser;
  wire [31:0] size   = (sof_wait && s_axis_tvalid && s_axis_tuser) ? regs[1*32 +: 32] : size_f;
  always_ff @(posedge clk) begin
    if (!rst_n || sof_in) begin
      for (int i = 0; i < NN; i++) coef_f[i*COEF_W +: COEF_W] <= regs[(KB + i)*32 +: COEF_W];
      shift_f <= regs[2*32 +: 5];
      size_f  <= regs[1*32 +: 32];
    end
  end

  logic frame; logic [15:0] frames;
  conv2d_core #(.N(N), .C(C), .CW(CW), .COEF_W(COEF_W), .MAX_W(MAX_W), .BORDER(BORDER)) u_core (
    .clk, .rst_n, .width_i(size[15:0]), .height_i(size[31:16]), .coef_i(coef_f), .shift_i(shift_f),
    .s_axis_tdata, .s_axis_tlast, .s_axis_tuser, .s_axis_tvalid, .s_axis_tready,
    .m_axis_tdata, .m_axis_tlast, .m_axis_tuser, .m_axis_tvalid, .m_axis_tready, .frame_o(frame), .sof_wait_o(sof_wait));
  always_ff @(posedge clk) if (!rst_n) frames <= '0; else if (frame) frames <= frames + 1'b1;

  always_comb begin
    rd = regs;
    rd[0*32 +: 32] = ID;
    rd[3*32 +: 32] = {16'd0, frames};
    rd[4*32 +: 32] = {8'(CW), 8'(C), 4'd0, 4'(COEF_W), 4'd0, 4'(N)};
    for (int i = 0; i < NN; i++) rd[(KB + i)*32 +: 32] = 32'($signed(regs[(KB + i)*32 +: COEF_W]));
  end
endmodule
