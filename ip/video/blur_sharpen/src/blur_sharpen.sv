// ***************
// Filename: blur_sharpen.sv
// Author: FPGA Cores 4 U
// Description: Blur and sharpen filter pair for AXI4-Stream video with an
//   AXI4-Lite register map. Version 1.0.0. Two conv2d_core stages are
//   always in line; MODE decides which kernel each stage runs, and a stage
//   that is not needed runs the identity kernel (pass-through), so the
//   latency and throughput are the same in every mode:
//     MODE  stage 1   stage 2   result
//      0    blur      identity  blurring only
//      1    sharpen   identity  sharpening only
//      2    sharpen   blur      sharpening, then blurring
//      3    blur      sharpen   blurring, then sharpening
//      4    identity  identity  pass-through (5-7 also)
//   The blur and sharpen kernels are programmable (reset: binomial blur and
//   unsharp mask, see conv2d_pkg). MODE, FRAME_SIZE, the kernels and shifts
//   are copied when a start-of-frame pixel enters, so a change applies from
//   the next frame and never splits one; stage 2 takes the copy belonging
//   to the frame it is filtering.
//   Registers (32-bit, ADDR_W = 9):
//     0x000 ID          RO "BLSH"
//     0x004 MODE        [2:0], reset 0
//     0x008 FRAME_SIZE  [15:0] width [31:16] height (>= (N+1)/2 each)
//     0x00C BLUR_SHIFT  [4:0]
//     0x010 SHARP_SHIFT [4:0]
//     0x014 STATUS      RO [2:0] mode of the last frame that entered
//                       [31:16] frames out
//     0x018 INFO        RO [3:0] N [11:8] COEF_W [23:16] C [31:24] CW
//     0x040 + 4*i       BLUR_K[i], signed, i = r*N + c
//     0x0C0 + 4*i       SHARP_K[i], signed
//   Each stage: out = clamp((sum(K*p) + round) >>> SHIFT, 0, 2^CW-1).
//   Data - C components of CW bits, tuser = SOF, tlast = EOL. Clock - clk.
//   Reset - synchronous rst_n (active low). Latency - 2 x conv2d_core.
//   Resources - 2 x N*N*C multipliers, 2 x (N-1) line buffers.
// Date: 2026-10-08
module blur_sharpen #(
  parameter int N      = 5,                        // kernel size: 3 or 5
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 2048,
  parameter int BORDER = 0,                        // 0 clamp to edge, 1 mirror
  parameter int AMOUNT = 1,                        // reset sharpening strength
  parameter logic [15:0] RESET_W = 16'd1920,
  parameter logic [15:0] RESET_H = 16'd1080
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [8:0]         s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [8:0]         s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
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
  localparam int NN = N * N, KW = NN * COEF_W;
  localparam int R_BLUR = 16, R_SHARP = 48, NREG = R_SHARP + NN;
  localparam logic [conv2d_pkg::KMAX*32-1:0] K_BLUR  = conv2d_pkg::blur_kernel(N);
  localparam logic [conv2d_pkg::KMAX*32-1:0] K_SHARP = conv2d_pkg::sharpen_kernel(N, AMOUNT);

  function automatic logic [NREG*32-1:0] reset_vals();
    logic [NREG*32-1:0] v;
    v = '0;
    v[2*32 +: 32] = {RESET_H, RESET_W};
    v[3*32 +: 32] = 32'(conv2d_pkg::blur_shift(N));
    v[4*32 +: 32] = 32'(conv2d_pkg::blur_shift(N));
    for (int i = 0; i < NN; i++) begin
      v[(R_BLUR + i)*32 +: 32]  = K_BLUR[i*32 +: 32];
      v[(R_SHARP + i)*32 +: 32] = K_SHARP[i*32 +: 32];
    end
    return v;
  endfunction

  logic [NREG*32-1:0] regs, rd;
  ip_axil_regs #(.ADDR_W(9), .NREG(NREG), .RESET_VALS(reset_vals())) u_regs (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .reg_o(regs),
    .wr_pulse_o(),
    .wr_data_o(),
    .rd_i(rd)
  );

  // ---------------- kernels selected by MODE ----------------
  logic [KW-1:0] k_blur, k_sharp, k_id;
  always_comb begin
    k_id = '0;
    k_id[((N / 2) * N + N / 2) * COEF_W +: COEF_W] = COEF_W'(1);
    for (int i = 0; i < NN; i++) begin
      k_blur[i*COEF_W +: COEF_W]  = regs[(R_BLUR + i)*32 +: COEF_W];
      k_sharp[i*COEF_W +: COEF_W] = regs[(R_SHARP + i)*32 +: COEF_W];
    end
  end
  wire [2:0] mode  = regs[1*32 +: 3];
  wire [4:0] sh_bl = regs[3*32 +: 5], sh_sh = regs[4*32 +: 5];
  wire       s1_blur = (mode == 3'd0 || mode == 3'd3), s1_sharp = (mode == 3'd1 || mode == 3'd2);
  wire       s2_blur = (mode == 3'd2),                 s2_sharp = (mode == 3'd3);
  wire [KW-1:0] k1 = s1_blur ? k_blur : s1_sharp ? k_sharp : k_id;
  wire [4:0]   sh1 = s1_blur ? sh_bl  : s1_sharp ? sh_sh   : 5'd0;
  wire [KW-1:0] k2 = s2_blur ? k_blur : s2_sharp ? k_sharp : k_id;
  wire [4:0]   sh2 = s2_blur ? sh_bl  : s2_sharp ? sh_sh   : 5'd0;

  // ---------------- per-frame copies ----------------
  // A: taken when a frame enters stage 1; B: stage 2's part of A, taken
  // when the same frame enters stage 2 (stage 1 is still on that frame).
  logic [KW-1:0] a_k1, a_k2, b_k2;
  logic [4:0] a_sh1, a_sh2, b_sh2;
  logic [31:0] a_size, b_size;
  logic [2:0] a_mode;
  logic [C*CW-1:0] x_d;
  logic x_l, x_u, x_v, x_r;
  wire sof1 = s_axis_tvalid && s_axis_tready && s_axis_tuser;
  wire sof2 = x_v && x_r && x_u;
  logic w1, w2;                                   // stage waits between frames (isp_window)
  wire [31:0] size1 = (w1 && s_axis_tvalid && s_axis_tuser) ? regs[2*32 +: 32] : a_size;
  wire [31:0] size2 = (w2 && x_v && x_u) ? a_size : b_size;
  always_ff @(posedge clk) begin
    if (!rst_n || sof1) begin
      a_k1 <= k1;
      a_sh1 <= sh1;
      a_k2 <= k2;
      a_sh2 <= sh2;
      a_size <= regs[2*32 +: 32];
      a_mode <= mode;
    end
    if (!rst_n || sof2) begin
      b_k2 <= rst_n ? a_k2 : k2;
      b_sh2 <= rst_n ? a_sh2 : sh2;
      b_size <= rst_n ? a_size : regs[2*32 +: 32];
    end
  end

  // ---------------- the two stages ----------------
  logic [15:0] frames;
  conv2d_core #(.N(N), .C(C), .CW(CW), .COEF_W(COEF_W), .MAX_W(MAX_W), .BORDER(BORDER)) u_stage1 (
    .clk,
    .rst_n,
    .width_i(size1[15:0]),
    .height_i(size1[31:16]),
    .coef_i(a_k1),
    .shift_i(a_sh1),
    .s_axis_tdata,
    .s_axis_tlast,
    .s_axis_tuser,
    .s_axis_tvalid,
    .s_axis_tready,
    .m_axis_tdata(x_d),
    .m_axis_tlast(x_l),
    .m_axis_tuser(x_u),
    .m_axis_tvalid(x_v),
    .m_axis_tready(x_r),
    .frame_o(),
    .sof_wait_o(w1)
  );
  conv2d_core #(.N(N), .C(C), .CW(CW), .COEF_W(COEF_W), .MAX_W(MAX_W), .BORDER(BORDER)) u_stage2 (
    .clk,
    .rst_n,
    .width_i(size2[15:0]),
    .height_i(size2[31:16]),
    .coef_i(b_k2),
    .shift_i(b_sh2),
    .s_axis_tdata(x_d),
    .s_axis_tlast(x_l),
    .s_axis_tuser(x_u),
    .s_axis_tvalid(x_v),
    .s_axis_tready(x_r),
    .m_axis_tdata,
    .m_axis_tlast,
    .m_axis_tuser,
    .m_axis_tvalid,
    .m_axis_tready,
    .frame_o(),
    .sof_wait_o(w2)
  );
  wire out_sof = m_axis_tvalid && m_axis_tready && m_axis_tuser;
  always_ff @(posedge clk)
    if (!rst_n) frames <= '0;
    else if (out_sof) frames <= frames + 1'b1;

  always_comb begin
    rd = regs;
    rd[0*32 +: 32] = 32'h424C_5348;                 // "BLSH"
    rd[5*32 +: 32] = {frames, 13'd0, a_mode};
    rd[6*32 +: 32] = {8'(CW), 8'(C), 4'd0, 4'(COEF_W), 4'd0, 4'(N)};
    for (int i = 0; i < NN; i++) begin
      rd[(R_BLUR + i)*32 +: 32]  = 32'($signed(regs[(R_BLUR + i)*32 +: COEF_W]));
      rd[(R_SHARP + i)*32 +: 32] = 32'($signed(regs[(R_SHARP + i)*32 +: COEF_W]));
    end
  end
endmodule
