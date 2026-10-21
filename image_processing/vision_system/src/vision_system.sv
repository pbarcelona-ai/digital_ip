// ***************
// Filename: vision_system.sv
// Author: FPGA Cores 4 U
// Description: Lens / geometry correction of an AXI4-Stream video (version
//   2.0.0): axi_lite_regs (register map, calibration), axis_in_ctrl (writes
//   a frame into the frame store), axis_out_ctrl (generates the corrected
//   frame from it) and the frame store (on-chip frame_buffer, or the SDR
//   SDRAM ext_frame_buffer with USE_EXT_FB). Golden model:
//   model/vision_system_model.py (frame exact; tb/python).
//     - BYPASS[0] (reset 1): frames pass from s_axis to m_axis unchanged. The
//       route is chosen when a frame's first pixel (tuser) is presented while
//       the core is idle, so it never changes inside a frame. With the
//       correction route, beats outside a frame (before its tuser) are
//       consumed and dropped (axis_in_ctrl).
//     - Correction: a whole frame is written into the store (T_LOAD), the
//       store finishes its writes (T_FLUSH), then the corrected frame is
//       generated (T_OUTPUT, axis_out_ctrl); the next frame is taken after
//       it. Frames are IMG_WIDTH x IMG_HEIGHT pixels (at most the store:
//       MAX_W x MAX_H on chip); the calibration and INTERP_MODE must not
//       change while STATUS.BUSY is set.
//     - CTRL[0] written with 1 resets the datapath for one clock (a frame in
//       progress is dropped); the registers keep their values.
//     - Pixels {B, G, R}, R in the LSBs; tuser = start of frame, tlast = end
//       of line; m_axis has back-pressure (axis_out_ctrl's credits).
//   AXI4-Lite register map: src/include/vision_system_regs.sv (ADDR_W 8),
//   listed in src/include/vision_system_regs.json.
//   Parameters: USE_EXT_FB (0 on-chip store, 1 SDRAM), FB_DEPTH (on-chip
//   store pixels, <= 2**ADDR_W; frames must fit), SDRAM_* (ext_frame_buffer).
//   Clock - clk (one domain; the SDRAM is clocked by it). Reset -
//   synchronous active low rst_n; CTRL[0] adds one clock of datapath reset.
//   Clock-domain crossings - none. Latency - a frame is output after it has
//   been stored; the first corrected pixel follows the start of output by
//   33 clocks (bilinear, fast models, on-chip store; measured), 52
//   (bicubic), about 73 / 92 (bilinear / bicubic with the slow models). Resources (Yosys, xc7, defaults) - 13.8k LUT,
//   10.1k FF, 425 DSP48E1, 1536 RAMB36 (the full MAX_W x MAX_H store,
//   frame_buffer), est. 8.3 ns. Errors - beats outside a frame are dropped;
//   a line of the wrong length is not reported (axis_in_ctrl's diagnostic
//   is not connected); frame sizes are clamped (axi_lite_regs).
// Date: 2026-10-21
module vision_system #(
  parameter int COORD_W = barrel_pkg::COORD_W,
  parameter int ADDR_W  = barrel_pkg::ADDR_W,
  parameter bit USE_EXT_FB = 1'b0,
  parameter int FB_DEPTH = barrel_pkg::MAX_W * barrel_pkg::MAX_H,   // on-chip store: pixels (<= 2**ADDR_W)
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
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.master m_axis,
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
  axil_if.slave s_axil,
  // SDR SDRAM (USE_EXT_FB; idle otherwise)
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
  localparam int PW = barrel_pkg::PIX_W;
  distortion_model_pkg::calib_params_t cfg;
  logic [COORD_W-1:0] img_width, img_height;
  logic               cfg_recip_busy, interp_mode, bypass, soft_rst, soft_q;
  logic               top_busy, frame_done_in, frame_out_done, out_busy, in_busy;
  logic               fb_wr_ready, fb_wr_idle, fb_rd_ready, fb_rd_valid;

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
    .interp_mode,
    .bypass,
    .soft_rst
  );
  // CTRL[0]: one clock of reset for the datapath (sequencing, controllers, store); the registers keep
  // their values
  always_ff @(posedge clk) soft_q <= rst_n && soft_rst;
  wire  core_rst_n = rst_n && !soft_q;

  // ---------------- sequencing: load a frame, let the store finish, output the corrected frame
  typedef enum logic [1:0] {T_LOAD, T_FLUSH, T_OUTPUT} tstate_t;
  tstate_t tstate;
  logic    capture_en, start_output;
  always_ff @(posedge clk) begin
    if (!core_rst_n) begin
      tstate <= T_LOAD;
      start_output <= 1'b0;
    end else begin
      start_output <= 1'b0;
      unique case (tstate)
        T_LOAD: if (frame_done_in) tstate <= T_FLUSH;
        T_FLUSH: if (fb_wr_idle) begin
          start_output <= 1'b1;
          tstate <= T_OUTPUT;
        end
        T_OUTPUT: if (frame_out_done) tstate <= T_LOAD;
        default: tstate <= T_LOAD;
      endcase
    end
  end
  // frame_done_in is registered: in its clock the sequencer is still in T_LOAD, so it also closes the
  // input (and the route below) until the frame stored has been corrected
  assign capture_en = (tstate == T_LOAD) && !frame_done_in && !cfg_recip_busy;
  assign top_busy   = (tstate != T_LOAD) || cfg_recip_busy || in_busy || out_busy;

  // ---------------- route: bypass or correction, chosen at a frame start while idle
  logic pass_q;
  wire  idle     = (tstate == T_LOAD) && !frame_done_in && !in_busy && !out_busy;
  wire  at_sof   = s_axis.tvalid && s_axis.tuser;
  wire  pass_now = (at_sof && idle) ? bypass : pass_q;
  // reset: the route of the register's value (BYPASS resets to 1; a soft reset keeps the register), so
  // beats arriving before the next frame start follow BYPASS
  always_ff @(posedge clk) begin
    if (!core_rst_n) pass_q <= !rst_n || bypass;
    else if (at_sof && idle) pass_q <= bypass;
  end
  axis_if #(.DATA_W(PW)) cin ();                 // into axis_in_ctrl
  axis_if #(.DATA_W(PW)) cout ();                // from axis_out_ctrl
  assign cin.tdata  = s_axis.tdata;
  assign cin.tlast  = s_axis.tlast;
  assign cin.tuser  = s_axis.tuser;
  assign cin.tkeep  = s_axis.tkeep;
  assign cin.tvalid = s_axis.tvalid && !pass_now;
  assign s_axis.tready = pass_now ? m_axis.tready : cin.tready;
  assign m_axis.tdata  = pass_now ? s_axis.tdata : cout.tdata;
  assign m_axis.tlast  = pass_now ? s_axis.tlast : cout.tlast;
  assign m_axis.tuser  = pass_now ? s_axis.tuser : cout.tuser;
  assign m_axis.tkeep  = '1;
  assign m_axis.tvalid = pass_now ? s_axis.tvalid : cout.tvalid;
  assign cout.tready   = !pass_now && m_axis.tready;

  // ---------------- frame store
  logic              fb_wr_en;
  logic [ADDR_W-1:0] fb_wr_addr;
  logic [PW-1:0]     fb_wr_data;
  logic              fb_rd_en;
  logic [ADDR_W-1:0] fb_rd_addr0, fb_rd_addr1, fb_rd_addr2, fb_rd_addr3;
  logic [PW-1:0]     fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3;
  if (USE_EXT_FB) begin : g_ext_frame_buffer
    ext_frame_buffer #(
      .PIX_W(PW),
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
      .rst_n(core_rst_n),
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
      .PIX_W(PW),
      .DEPTH(FB_DEPTH),
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
    always_ff @(posedge clk) begin               // the words of a read one clock after it
      if (!core_rst_n) fb_rd_valid <= 1'b0;
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

  // ---------------- input and output controllers
  logic err_line_len;
  axis_in_ctrl #(
    .COORD_W(COORD_W),
    .ADDR_W(ADDR_W)
  ) u_in (
    .clk,
    .rst_n(core_rst_n),
    .capture_en,
    .fb_wr_ready,
    .img_width,
    .img_height,
    .frame_done(frame_done_in),
    .busy(in_busy),
    .err_line_len,
    .s_axis(cin),
    .wr_en(fb_wr_en),
    .wr_addr(fb_wr_addr),
    .wr_data(fb_wr_data)
  );
  axis_out_ctrl #(
    .COORD_W(COORD_W),
    .ADDR_W(ADDR_W)
  ) u_out (
    .clk,
    .rst_n(core_rst_n),
    .start_output,
    .img_width,
    .img_height,
    .interp_mode,
    .busy(out_busy),
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
    .m_axis(cout)
  );
  // not used: the line-length diagnostic (frames must be IMG_WIDTH wide), tkeep
  wire unused_ok = &{1'b0, err_line_len, cout.tkeep, 1'b0};
endmodule
