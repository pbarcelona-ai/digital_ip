// ***************
// Filename: vision_system.sv
// Author: FPGA Cores 4 U
// Description: Top-level lens-distortion-correction core. Integrates
// axis_in_ctrl, frame_buffer, axis_out_ctrl, and axi_lite_regs,
// and sequences the load-then-output FSM (T_LOAD/T_OUTPUT) that
// buffers a whole input frame before streaming the corrected
// output.
// Date: September 26, 2026
// ***************
// =============================================================================
// vision_system.sv
//
// Top-level barrel-distortion-correction core.
//
//   - s_axis_*: AXI4-Stream video input. Each line = IMG_WIDTH back-to-back
//     beats (tlast on the final pixel), followed by >=5 idle cycles before
//     the next line. tuser marks the first pixel of the frame.
//   - m_axis_*: AXI4-Stream video output, same per-line/idle-gap timing,
//     carrying the corrected frame.
//   - s_axil_*: AXI4-Lite configuration (k1/k2/k3, image size, center,
//     scale -- see axi_lite_regs.sv for the register map).
//
// Sequencing: a whole input frame is captured into the frame buffer, then
// the corrected frame is generated and streamed out; the next input frame
// is only accepted once the previous frame's output has finished. See
// docs/README for the ping-pong-buffer extension needed for fully
// overlapped (back-to-back, no dead time) frame-rate operation.
// =============================================================================

module vision_system #(
  parameter int COORD_W = barrel_pkg::COORD_W,
  parameter int ADDR_W  = barrel_pkg::ADDR_W,
  parameter bit USE_EXT_FB = 1'b0,
  parameter int SDRAM_DQ_W = 64,
  parameter int SDRAM_A_W = 13,
  parameter int SDRAM_COL_W = 10,
  parameter int SDRAM_FIFO_DEPTH = 32,
  parameter int SDRAM_INIT_WAIT_CYCLES = 20000,
  parameter int SDRAM_T_RP_CYCLES = 2,
  parameter int SDRAM_T_RCD_CYCLES = 2,
  parameter int SDRAM_T_RAS_CYCLES = 5,
  parameter int SDRAM_T_RFC_CYCLES = 7,
  parameter int SDRAM_T_MRD_CYCLES = 2,
  parameter int SDRAM_T_WR_CYCLES = 2,
  parameter int SDRAM_CAS_LATENCY = 2,
  parameter int SDRAM_REFRESH_INTERVAL_CYCLES = 780
) (
  input  logic clk,
  input  logic rst_n,

  // AXI4-Stream slave (video in)
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = barrel_pkg::PIX_W
  axis_if.slave s_axis,

  // AXI4-Stream master (video out)
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = barrel_pkg::PIX_W
  axis_if.master m_axis,

  // AXI4-Lite slave (config)
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
  axil_if.slave s_axil,

  output wire          sdram_clk,
  output wire          sdram_cke,
  output wire          sdram_cs_n,
  output wire          sdram_ras_n,
  output wire          sdram_cas_n,
  output wire          sdram_we_n,
  output wire [SDRAM_A_W-1:0] sdram_a,
  output wire [1:0]    sdram_ba,
  output wire [SDRAM_DQ_W/8-1:0] sdram_dqm,
  inout  wire [SDRAM_DQ_W-1:0] sdram_dq
);

  // ---- config regs ---------------------------------------------------
  distortion_model_pkg::calib_params_t cfg;
  logic [COORD_W-1:0] img_width, img_height;
  logic                cfg_recip_busy;
  logic                interp_mode;

  logic top_busy, frame_done_in, frame_out_done;
  logic fb_wr_ready, fb_wr_idle, fb_rd_ready, fb_rd_valid;

  axi_lite_regs #(.COORD_W(COORD_W)) u_regs (
    .clk,
    .rst_n,
    .s_axil(s_axil),
    .top_busy,
    .top_frame_done_pulse(frame_out_done),
    .cfg_out(cfg),
    .img_width,
    .img_height,
    .cfg_recip_busy,
    .interp_mode
  );

  // ---- top sequencing FSM ---------------------------------------------
  typedef enum logic [1:0] {T_LOAD, T_FLUSH, T_OUTPUT} tstate_t;
  tstate_t tstate;

  logic capture_en, start_output;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_LOAD;
      start_output <= 1'b0;
    end else begin
      start_output <= 1'b0;
      unique case (tstate)
        T_LOAD: begin
          if (frame_done_in) begin
            tstate <= T_FLUSH;
          end
        end
        T_FLUSH: begin
          if (fb_wr_idle) begin
            start_output <= 1'b1;
            tstate <= T_OUTPUT;
          end
        end
        T_OUTPUT: begin
          if (frame_out_done) tstate <= T_LOAD;
        end
        default: tstate <= T_LOAD;
      endcase
    end
  end

  assign capture_en = (tstate == T_LOAD) && !cfg_recip_busy;
  assign top_busy   = (tstate != T_LOAD) || cfg_recip_busy;

  // ---- frame buffer -----------------------------------------------------
  logic               fb_wr_en;
  logic [ADDR_W-1:0]  fb_wr_addr;
  logic [barrel_pkg::PIX_W-1:0]   fb_wr_data;
  logic               fb_rd_en;
  logic [ADDR_W-1:0]  fb_rd_addr0, fb_rd_addr1, fb_rd_addr2, fb_rd_addr3;
  logic [barrel_pkg::PIX_W-1:0]   fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3;

  generate
    if (USE_EXT_FB) begin : g_ext_frame_buffer
      ext_frame_buffer #(
        .PIX_W(barrel_pkg::PIX_W),
        .ADDR_W(ADDR_W),
        .SDRAM_DQ_W(SDRAM_DQ_W),
        .SDRAM_A_W(SDRAM_A_W),
        .COL_W(SDRAM_COL_W),
        .FIFO_DEPTH(SDRAM_FIFO_DEPTH),
        .INIT_WAIT_CYCLES(SDRAM_INIT_WAIT_CYCLES),
        .T_RP_CYCLES(SDRAM_T_RP_CYCLES),
        .T_RCD_CYCLES(SDRAM_T_RCD_CYCLES),
        .T_RAS_CYCLES(SDRAM_T_RAS_CYCLES),
        .T_RFC_CYCLES(SDRAM_T_RFC_CYCLES),
        .T_MRD_CYCLES(SDRAM_T_MRD_CYCLES),
        .T_WR_CYCLES(SDRAM_T_WR_CYCLES),
        .CAS_LATENCY(SDRAM_CAS_LATENCY),
        .REFRESH_INTERVAL_CYCLES(SDRAM_REFRESH_INTERVAL_CYCLES)
      ) u_fb (
        .clk,
        .rst_n,
        .wr_en(fb_wr_en),
        .wr_ready(fb_wr_ready),
        .wr_addr(fb_wr_addr),
        .wr_data(fb_wr_data),
        .wr_idle(fb_wr_idle),
        .rd_en(fb_rd_en),
        .rd_ready(fb_rd_ready),
        .rd_addr0(fb_rd_addr0),
        .rd_addr1(fb_rd_addr1),
        .rd_addr2(fb_rd_addr2),
        .rd_addr3(fb_rd_addr3),
        .rd_valid(fb_rd_valid),
        .rd_data0(fb_rd_data0),
        .rd_data1(fb_rd_data1),
        .rd_data2(fb_rd_data2),
        .rd_data3(fb_rd_data3),
        .sdram_clk,
        .sdram_cke,
        .sdram_cs_n,
        .sdram_ras_n,
        .sdram_cas_n,
        .sdram_we_n,
        .sdram_a,
        .sdram_ba,
        .sdram_dqm,
        .sdram_dq
      );
    end else begin : g_bram_frame_buffer
      frame_buffer #(
        .PIX_W(barrel_pkg::PIX_W),
        .ADDR_W(ADDR_W)
      ) u_fb (
        .clk,
        .wr_en(fb_wr_en),
        .wr_addr(fb_wr_addr),
        .wr_data(fb_wr_data),
        .rd_en(fb_rd_en),
        .rd_addr0(fb_rd_addr0),
        .rd_addr1(fb_rd_addr1),
        .rd_addr2(fb_rd_addr2),
        .rd_addr3(fb_rd_addr3),
        .rd_data0(fb_rd_data0),
        .rd_data1(fb_rd_data1),
        .rd_data2(fb_rd_data2),
        .rd_data3(fb_rd_data3)
      );
      assign fb_wr_ready = 1'b1;
      assign fb_wr_idle = 1'b1;
      assign fb_rd_ready = 1'b1;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fb_rd_valid <= 1'b0;
        else fb_rd_valid <= fb_rd_en;
      end
      assign sdram_clk = 1'b0;
      assign sdram_cke = 1'b0;
      assign sdram_cs_n = 1'b1;
      assign sdram_ras_n = 1'b1;
      assign sdram_cas_n = 1'b1;
      assign sdram_we_n = 1'b1;
      assign sdram_a = '0;
      assign sdram_ba = '0;
      assign sdram_dqm = '1;
      assign sdram_dq = {SDRAM_DQ_W{1'bz}};
    end
  endgenerate

  // ---- input controller ---------------------------------------------
  axis_in_ctrl #(
    .COORD_W(COORD_W),
    .ADDR_W(ADDR_W)
  ) u_in (
    .clk,
    .rst_n,
    .capture_en,
    .fb_wr_ready,
    .img_width,
    .img_height,
    .frame_done(frame_done_in),
    .busy(),
    .err_line_len(),
    .s_axis(s_axis),
    .wr_en(fb_wr_en),
    .wr_addr(fb_wr_addr),
    .wr_data(fb_wr_data)
  );

  // ---- output controller ---------------------------------------------
  axis_out_ctrl #(
    .COORD_W(COORD_W),
    .ADDR_W(ADDR_W),
    .USE_EXT_FB(USE_EXT_FB)
  ) u_out (
    .clk,
    .rst_n,
    .start_output,
    .img_width,
    .img_height,
    .interp_mode,
    .busy(),
    .frame_out_done,
    .cfg,
    .fb_rd_en,
    .fb_rd_addr0,
    .fb_rd_addr1,
    .fb_rd_addr2,
    .fb_rd_addr3,
    .fb_rd_data0,
    .fb_rd_data1,
    .fb_rd_data2,
    .fb_rd_data3,
    .fb_rd_ready,
    .fb_rd_valid,
    .m_axis(m_axis)
  );

endmodule
