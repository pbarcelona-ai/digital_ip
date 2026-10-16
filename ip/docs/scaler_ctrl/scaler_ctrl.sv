// ***************
// Filename: scaler_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Common control block for all scaler IPs.
//   * AXI4-Lite slave (axil_regbus) implementing the common registers
//   * forwards addresses >= 0x040 to the IP-specific ext_* bus
//   * captures AXI4-Stream frames (tuser = SOF, tlast = EOL) into the
//     frame store, dropping data before SOF and flagging errors
//   * frame sequencing in one of three buffering modes:
//       NBUF = 1, LB_ROWS = 0  frame buffer: capture a frame, then generate
//                              it; input is stalled while generating
//       NBUF = 2, LB_ROWS = 0  double buffer (ping-pong): the next frame is
//                              captured into the other buffer while the
//                              current one is generated; input only stalls
//                              if both buffers are busy
//       LB_ROWS > 0            line buffer: the frame store is a ring of
//                              LB_ROWS lines; generation starts at SOF and
//                              runs concurrently with capture, with row-level
//                              flow control in both directions (latency of a
//                              few lines). STEP_Y must be >= 0.
//     Line-buffer flow control: the IP reports the source y coordinate of the
//     next pixel its DDA will emit (lb_nxt_*) and of the pixels already
//     emitted but whose rows are not yet read (lb_o_*, lb_a_*). From these the
//     block derives
//       need(y) = clamp(((y + LB_RND) >>> 16) - LB_CTR + LB_TAPS - 1, 0, H-1)
//       top(y)  = clamp(((y + LB_RND) >>> 16) - LB_CTR,               0, H-1)
//     lb_hold = 1 while row need(next) has not been fully received, and input
//     row r is accepted only while r < top(oldest in-flight pixel) + LB_ROWS.
//   Common register map (byte offsets, 32-bit):
//     0x000 CTRL      [0] ENABLE (RW) - run continuously while set
//     0x004 STATUS    [0] BUSY [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR*
//                     [4] CAPTURING [5] GENERATING   (* = write 1 clears)
//     0x008 IN_SIZE   [15:0] width [31:16] height
//     0x00C OUT_SIZE  [15:0] width [31:16] height
//     0x010 STEP_X    unsigned 16.16 source pixels per output pixel
//     0x014 STEP_Y    unsigned 16.16
//     0x018 OFFS_X    signed 16.16 source position of output pixel 0
//     0x01C OFFS_Y    signed 16.16
//     0x020 FRAME_CNT (RO) frames completed
//     0x024 IP_ID     (RO) ASCII IP tag
//     0x028 CAPS      (RO) IP capability word
//     0x02C MAX_SIZE  (RO) [15:0] MAX_W [31:16] MAX_H
//     0x040+          forwarded to the IP (1-cycle read latency)
// Date: 2026-09-26

module scaler_ctrl #(
  parameter int          PIX_W   = 24,     // pixel width in bits
  parameter int          ADDR_W  = 14,     // AXI-Lite address width
  parameter int          MAX_W   = 1920,   // frame buffer width (RO reg)
  parameter int          MAX_H   = 1080,   // frame buffer height (RO reg)
  parameter logic [31:0] IP_ID   = 32'h0,  // value of the IP_ID register
  parameter logic [31:0] CAPS    = 32'h0,  // value of the CAPS register
  parameter int          NBUF    = 1,      // 1 = single, 2 = double frame buffer
  parameter int          LB_ROWS = 0,      // > 0: line-buffer mode, ring size
  parameter int          LB_TAPS = 1,      // line-buffer mode: vertical taps
  parameter int          LB_CTR  = 0,      //   window top = int(y) - LB_CTR
  parameter int          LB_RND  = 0       //   rounding added to y (16.16)
)(
  input  logic               clk,         // clock
  input  logic               rst_n,       // async reset, active low
  // AXI4-Lite slave
  input  logic [ADDR_W-1:0]  s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [ADDR_W-1:0]  s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  // AXI4-Stream video input
  input  logic [PIX_W-1:0]   s_axis_tdata,   // pixel
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,  // high only while capturing
  input  logic               s_axis_tuser,   // start of frame
  input  logic               s_axis_tlast,   // end of line
  // Frame buffer write port
  output logic               fb_we,          // write strobe
  output logic [15:0]        fb_wx,          // pixel column
  output logic [15:0]        fb_wy,          // pixel row
  output logic [PIX_W-1:0]   fb_wdata,       // pixel data
  output logic               fb_wbuf,        // buffer written (NBUF = 2)
  output logic               gen_buf,        // buffer to generate from
  // Generation handshake
  output logic               gen_start,   // 1-cycle pulse, frame captured
  input  logic               gen_done,    // 1-cycle pulse, last output pixel sent
  // Line-buffer flow control (ignored when LB_ROWS = 0)
  input  logic signed [31:0] lb_nxt_y,    // y of the next pixel the DDA emits
  input  logic               lb_nxt_v,    //   valid (DDA busy)
  input  logic signed [31:0] lb_o_y,      // y of the DDA output register
  input  logic               lb_o_v,
  input  logic signed [31:0] lb_a_y,      // y of the pixel in read stage A
  input  logic               lb_a_v,
  output logic               lb_hold,     // 1: DDA must not emit (insert bubble)
  // Configuration registers (static while a frame is processed)
  output logic [15:0]        cfg_in_w,
  output logic [15:0]        cfg_in_h,
  output logic [15:0]        cfg_out_w,
  output logic [15:0]        cfg_out_h,
  output logic [31:0]        cfg_step_x,
  output logic [31:0]        cfg_step_y,
  output logic signed [31:0] cfg_offs_x,
  output logic signed [31:0] cfg_offs_y,
  // IP-specific register bus (addresses >= 0x040)
  output logic               ext_wr,
  output logic [ADDR_W-1:0]  ext_waddr,
  output logic [31:0]        ext_wdata,
  output logic               ext_rd,
  output logic [ADDR_W-1:0]  ext_raddr,
  input  logic [31:0]        ext_rdata    // valid the cycle after ext_rd
);
