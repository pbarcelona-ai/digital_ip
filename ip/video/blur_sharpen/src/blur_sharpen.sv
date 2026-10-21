// ***************
// Filename: blur_sharpen.sv
// Author: FPGA Cores 4 U
// Description: Blur and sharpen filter pair for AXI4-Stream video with an
//   AXI4-Lite register map (version: the VERSION register). Two conv2d_core stages are
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
//   Registers on the cfg_* / sts_* ports; blur_sharpen_top.sv is the block
//   with its AXI4-Lite register map (src/include/blur_sharpen_regs.sv,
//   ADDR_W = 9): ID "BLSH" / VERSION / DATE at 0x000-0x008, MODE
//   0x014, FRAME_SIZE 0x018, BLUR_SHIFT 0x01C, SHARP_SHIFT 0x020, STATUS
//   0x024, INFO 0x028, BLUR_K[i] 0x050 + 4 i, SHARP_K[i] 0x0D0 + 4 i.
//   Each stage: out = clamp((sum(K*p) + round) >>> SHIFT, 0, 2^CW-1).
//   Frames match FRAME_SIZE and have at least 14 pixels (each side >= R + 1):
//   copy A is replaced when the next frame enters stage 1, and up to 13
//   beats can be between stage 1's scan and stage 2 (isp_window 5, MAC 4,
//   output FIFO 4), so a smaller frame could reach stage 2 after the next
//   one took over A. A and B load the register values while rst_n is low.
//   Golden model: model/blur_sharpen_model.py (frame exact, tb/python).
//   Data - C components of CW bits, tuser = SOF, tlast = EOL. Clock - clk.
//   Reset - synchronous rst_n (active low). Latency - 2 x conv2d_core.
//   Resources - 2 x N*N*C multipliers, 2 x (N-1) line buffers.
// Date: 2026-10-21
module blur_sharpen #(
  parameter int N      = 5,                        // kernel size: 3 or 5
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int COEF_W = 12,
  parameter int MAX_W  = 2048,
  parameter int BORDER = 0,                        // 0 clamp to edge, 1 mirror
  /* verilator lint_off UNUSEDPARAM */             // used by the register map (blur_sharpen_top)
  parameter int AMOUNT = 1,                        // reset sharpening strength
  parameter logic [15:0] RESET_W = 16'd1920,
  parameter logic [15:0] RESET_H = 16'd1080
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic               clk,
  input  logic               rst_n,
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = C*CW
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = C*CW
  axis_if.master m_axis,
  // register ports
  // regs: blur_sharpen_regs_if.core (src/include/blur_sharpen_regs_if.sv)
  blur_sharpen_regs_if.core regs
);
  localparam int NN = N * N, KW = NN * COEF_W;

  // ---------------- registers (cfg_* / sts_* ports, the map is in blur_sharpen_top)
  logic [2:0] mode;
  logic [31:0] frame_size;
  logic [4:0] sh_bl, sh_sh;
  logic [NN*COEF_W-1:0] kb_regs, ks_regs;


  // ---------------- kernels selected by MODE ----------------
  logic [KW-1:0] k_blur, k_sharp, k_id;
  always_comb begin
    k_id = '0;
    k_id[((N / 2) * N + N / 2) * COEF_W +: COEF_W] = COEF_W'(1);
    for (int i = 0; i < NN; i++) begin
      k_blur[i*COEF_W +: COEF_W]  = kb_regs[i*COEF_W +: COEF_W];
      k_sharp[i*COEF_W +: COEF_W] = ks_regs[i*COEF_W +: COEF_W];
    end
  end
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
  wire sof1 = s_axis.tvalid && s_axis.tready && s_axis.tuser;
  wire sof2 = x_v && x_r && x_u;
  logic w1, w2;                                   // stage waits between frames (isp_window)
  logic frame1, frame2;                           // a stage took its kernel (not used)
  wire [31:0] size1 = (w1 && s_axis.tvalid && s_axis.tuser) ? frame_size : a_size;
  wire [31:0] size2 = (w2 && x_v && x_u) ? a_size : b_size;
  always_ff @(posedge clk) begin
    if (!rst_n || sof1) begin
      a_k1 <= k1;
      a_sh1 <= sh1;
      a_k2 <= k2;
      a_sh2 <= sh2;
      a_size <= frame_size;
      a_mode <= mode;
    end
    if (!rst_n || sof2) begin
      b_k2 <= rst_n ? a_k2 : k2;
      b_sh2 <= rst_n ? a_sh2 : sh2;
      b_size <= rst_n ? a_size : frame_size;
    end
  end

  // ---------------- the two stages ----------------
  logic [15:0] frames;
  axis_if #(.DATA_W(C*CW)) u_stage1_m_axis ();
  assign x_d = u_stage1_m_axis.tdata;
  assign x_l = u_stage1_m_axis.tlast;
  assign x_u = u_stage1_m_axis.tuser;
  assign x_v = u_stage1_m_axis.tvalid;
  assign u_stage1_m_axis.tready = x_r;
  conv2d_core #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_stage1 (
    .clk,
    .rst_n,
    .width_i(size1[15:0]),
    .height_i(size1[31:16]),
    .coef_i(a_k1),
    .shift_i(a_sh1),
    .s_axis(s_axis),
    .m_axis(u_stage1_m_axis),
    .frame_o(frame1),
    .sof_wait_o(w1)
  );
  axis_if #(.DATA_W(C*CW)) u_stage2_s_axis ();
  assign u_stage2_s_axis.tdata = x_d;
  assign u_stage2_s_axis.tlast = x_l;
  assign u_stage2_s_axis.tuser = x_u;
  assign u_stage2_s_axis.tvalid = x_v;
  assign x_r = u_stage2_s_axis.tready;
  wire out_sof = m_axis.tvalid && m_axis.tready && m_axis.tuser;
  always_ff @(posedge clk)
    if (!rst_n) frames <= '0;
    else if (out_sof) frames <= frames + 1'b1;
  // register ports (the map blur_sharpen_regs is in the wrapper, src/blur_sharpen_top.sv)
  assign mode = regs.cfg_mode;
  assign frame_size = regs.cfg_frame_size;
  assign sh_bl = regs.cfg_blur_shift;
  assign sh_sh = regs.cfg_sharp_shift;
  assign regs.sts_status = {frames, 13'd0, a_mode};
  assign regs.sts_info = {8'(CW), 8'(C), 4'd0, 4'(COEF_W), 4'd0, 4'(N)};
  assign kb_regs = regs.cfg_blur_k;
  assign ks_regs = regs.cfg_sharp_k;
  conv2d_core #(
    .N(N),
    .C(C),
    .CW(CW),
    .COEF_W(COEF_W),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_stage2 (
    .clk,
    .rst_n,
    .width_i(size2[15:0]),
    .height_i(size2[31:16]),
    .coef_i(b_k2),
    .shift_i(b_sh2),
    .s_axis(u_stage2_s_axis),
    .m_axis(m_axis),
    .frame_o(frame2),
    .sof_wait_o(w2)
  );
  // not used: the registers' write pulses (they act by value), the stages' frame_o
  wire unused_ok = &{1'b0, regs.cfg_mode_wr, regs.cfg_frame_size_wr, regs.cfg_blur_shift_wr,
                     regs.cfg_sharp_shift_wr, regs.cfg_blur_k_wr, regs.cfg_sharp_k_wr, frame1, frame2, 1'b0};
endmodule
