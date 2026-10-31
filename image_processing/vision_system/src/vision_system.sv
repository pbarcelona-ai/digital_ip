// ***************
// Filename: vision_system.sv
// Author: FPGA Cores 4 U
// Description: Lens / geometry correction of an AXI4-Stream video (version
//   2.1.0): axi_lite_regs (register map, calibration), axis_in_ctrl (writes
//   a frame into the frame store), axis_out_ctrl (generates the corrected
//   frame from it) and the frame store (on-chip frame_buffer, the SDR SDRAM
//   ext_frame_buffer with USE_EXT_FB, or the DDR ddr_frame_store with
//   USE_DDR_FB, an AXI4 master of the shared DDR controller). Golden model:
//   model/vision_system_model.py (frame exact; tb/python).
//     - BYPASS[0] (reset 1): frames pass from s_axis to m_axis unchanged. The
//       route is chosen when a frame's first pixel (tuser) is presented while
//       the core is idle (nothing stored or being output), so it never
//       changes inside a frame. With the correction route, beats outside a
//       frame (before its tuser) are consumed and dropped (axis_in_ctrl).
//     - Correction, single store (on chip, SDRAM): a whole frame is written
//       into the store (T_LOAD), the store finishes its writes (T_FLUSH), then
//       the corrected frame is generated (T_OUTPUT, axis_out_ctrl); the next
//       frame is taken after it.
//     - Correction, DDR (USE_DDR_FB, double-buffered): a frame is written into
//       buffer wbuf (I_LOAD); once its writes are in memory (I_FLUSH) the
//       buffer is full and the writer goes on into the other buffer as soon
//       as it is free (I_WAIT until then): the input does not wait for the
//       output while the output keeps up. The output starts on the full
//       buffer while idle (pulsing the store's rd_flush) and frees it at its
//       end. Frames leave in the order they arrived.
//     - Frames are IMG_WIDTH x IMG_HEIGHT pixels (at most the store: FB_DEPTH
//       on chip, 2**ADDR_W in SDRAM or DDR); the calibration and INTERP_MODE
//       must not change while STATUS.BUSY is set.
//     - CTRL[0] written with 1 resets the datapath for one clock (a frame in
//       progress is dropped); the registers keep their values.
//     - Pixels {B, G, R}, R in the LSBs; tuser = start of frame, tlast = end
//       of line; m_axis has back-pressure (axis_out_ctrl's credits).
//   AXI4-Lite register map: src/include/vision_system_regs.sv (ADDR_W 8),
//   listed in src/include/vision_system_regs.json.
//   Parameters: USE_EXT_FB (1 SDRAM), USE_DDR_FB (1 DDR; not both), FB_DEPTH
//   (on-chip store pixels, <= 2**ADDR_W; frames must fit), SDRAM_*
//   (ext_frame_buffer), DDR_* (ddr_frame_store: AXI data / address / ID
//   widths, the two buffers' byte addresses, the cache).
//   Clock - clk (one domain; the SDRAM is clocked by it, the DDR controller's
//   AXI port runs on it). Reset - synchronous active low rst_n; CTRL[0] adds
//   one clock of datapath reset. Clock-domain crossings - none. Latency - a
//   frame is output after it has been stored; the first corrected pixel
//   follows the start of output by 33 clocks (bilinear, fast models, on-chip
//   store; measured), 52 (bicubic), about 73 / 92 (bilinear / bicubic with
//   the slow models); more with the SDRAM or DDR stores (their read latency).
//   Resources (Yosys, xc7, defaults) - 13.8k LUT, 10.1k FF, 425 DSP48E1,
//   1536 RAMB36 (the full MAX_W x MAX_H store, frame_buffer), est. 8.3 ns.
//   Errors - beats outside a frame are dropped; a line of the wrong length
//   is not reported (axis_in_ctrl's diagnostic is not connected); frame sizes
//   are clamped (axi_lite_regs).
// Date: 2026-10-25
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
  parameter int SDRAM_REFRESH_INTERVAL_CYCLES = 780,
  parameter bit USE_DDR_FB = 1'b0,                                   // 1: DDR store (ddr_frame_store)
  parameter int DDR_DATA_W = 256,                                    // AXI data bits
  parameter int DDR_ADDR_W = 32,                                     // AXI byte address bits
  parameter int DDR_ID_W = 4,                                        // AXI ID bits
  parameter logic [DDR_ADDR_W-1:0] DDR_BASE0 = '0,                   // byte address of buffer 0
  parameter logic [DDR_ADDR_W-1:0] DDR_BASE1 = DDR_ADDR_W'(1) << (ADDR_W + 2),   // of buffer 1
  parameter int DDR_LINE_PIX = 32,                                   // cache line pixels
  parameter int DDR_CACHE_LINES = 64                                 // cache lines
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
  inout  wire [SDRAM_DQ_W-1:0] sdram_dq,
  // AXI4 master to a DDR controller port (USE_DDR_FB; idle otherwise)
  output logic [DDR_ID_W-1:0]     m_axi_awid,
  output logic [DDR_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [DDR_DATA_W-1:0]   m_axi_wdata,
  output logic [DDR_DATA_W/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [DDR_ID_W-1:0]     m_axi_bid,
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,
  output logic [DDR_ID_W-1:0]     m_axi_arid,
  output logic [DDR_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [DDR_ID_W-1:0]     m_axi_rid,
  input  logic [DDR_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready
);
  localparam int PW = barrel_pkg::PIX_W;
  if (USE_EXT_FB && USE_DDR_FB) begin : g_bad_store
    $error("vision_system: USE_EXT_FB and USE_DDR_FB are exclusive");
  end
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

  // ---------------- sequencing
  logic capture_en, start_output, idle, wbuf, rbuf;
  if (USE_DDR_FB) begin : g_seq_dbuf
    // double-buffered (DDR store): the writer fills buffer wb; a frame whose writes are in memory makes
    // its buffer full; the output starts on the full buffer while idle and frees it at its end
    localparam logic [1:0] I_LOAD = 2'd0, I_FLUSH = 2'd1, I_WAIT = 2'd2;
    logic [1:0] istate, full;
    logic       wb, rb, reading;
    wire        other_free = !full[!wb] && !(reading && rb == !wb);
    wire        start_buf  = !full[0];                 // the full buffer (only one while not reading)
    wire        can_start  = !reading && full != 2'b00;
    always_ff @(posedge clk) begin
      if (!core_rst_n) begin
        istate <= I_LOAD;
        full <= '0;
        wb <= 1'b0;
        rb <= 1'b0;
        reading <= 1'b0;
        start_output <= 1'b0;
      end else begin
        start_output <= 1'b0;
        unique case (istate)
          I_LOAD: if (frame_done_in) istate <= I_FLUSH;
          I_FLUSH: if (fb_wr_idle) begin
            full[wb] <= 1'b1;
            if (other_free) begin
              wb <= !wb;
              istate <= I_LOAD;
            end else begin
              istate <= I_WAIT;
            end
          end
          I_WAIT: if (other_free) begin
            wb <= !wb;
            istate <= I_LOAD;
          end
          default: istate <= I_LOAD;
        endcase
        if (can_start) begin
          start_output <= 1'b1;
          rb <= start_buf;
          reading <= 1'b1;
        end
        if (frame_out_done) begin                      // rb != wb while reading: other bit than full[wb]
          full[rb] <= 1'b0;
          reading <= 1'b0;
        end
      end
    end
    // frame_done_in is registered: in its clock the writer is still in I_LOAD, so it also closes the input
    assign capture_en = (istate == I_LOAD) && !frame_done_in && !cfg_recip_busy;
    assign top_busy   = (istate != I_LOAD) || reading || full != 2'b00 || cfg_recip_busy || in_busy || out_busy;
    assign idle       = (istate == I_LOAD) && !frame_done_in && !in_busy && !out_busy && !reading &&
                        full == 2'b00;
    assign wbuf       = wb;
    assign rbuf       = rb;
  end else begin : g_seq_single
    // single store: load a frame, let the store finish, output the corrected frame
    typedef enum logic [1:0] {T_LOAD, T_FLUSH, T_OUTPUT} tstate_t;
    tstate_t tstate;
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
    assign idle       = (tstate == T_LOAD) && !frame_done_in && !in_busy && !out_busy;
    assign wbuf       = 1'b0;
    assign rbuf       = 1'b0;
  end

  // ---------------- route: bypass or correction, chosen at a frame start while idle
  logic pass_q;
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
  // tready: the route of pass_now with the frame start taken from tuser alone (equal to pass_now
  // whenever tvalid is high; tvalid not used), so tready never depends on tvalid: a source whose tvalid
  // looks at tready (vs_stream_adapter's admission) forms no combinational loop
  wire  pass_rdy = (s_axis.tuser && idle) ? bypass : pass_q;
  assign s_axis.tready = pass_rdy ? m_axis.tready : cin.tready;
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
  if (USE_DDR_FB) begin : g_ddr_frame_store
    ddr_frame_store #(
      .PIX_W(PW),
      .ADDR_W(ADDR_W),
      .DATA_W(DDR_DATA_W),
      .AXI_ADDR_W(DDR_ADDR_W),
      .ID_W(DDR_ID_W),
      .BASE0(DDR_BASE0),
      .BASE1(DDR_BASE1),
      .LINE_PIX(DDR_LINE_PIX),
      .CACHE_LINES(DDR_CACHE_LINES)
    ) u_fb (
      .clk,
      .rst_n,                                      // the controller's reset: no AXI transaction abandoned
      .wr_en(fb_wr_en),
      .wr_ready(fb_wr_ready),
      .wr_addr(fb_wr_addr),
      .wr_data(fb_wr_data),
      .wr_buf(wbuf),
      .wr_idle(fb_wr_idle),
      .rd_en(fb_rd_en),
      .rd_ready(fb_rd_ready),
      .rd_addr0(fb_rd_addr0),
      .rd_addr1(fb_rd_addr1),
      .rd_addr2(fb_rd_addr2),
      .rd_addr3(fb_rd_addr3),
      .rd_buf(rbuf),
      .rd_flush(start_output),                     // the output's start: the buffer's frame is new
      .clear(soft_q),                              // CTRL[0]: the read in progress dropped
      .rd_valid(fb_rd_valid),
      .rd_data0(fb_rd_data0),
      .rd_data1(fb_rd_data1),
      .rd_data2(fb_rd_data2),
      .rd_data3(fb_rd_data3),
      .m_axi_awid,
      .m_axi_awaddr,
      .m_axi_awlen,
      .m_axi_awsize,
      .m_axi_awburst,
      .m_axi_awvalid,
      .m_axi_awready,
      .m_axi_wdata,
      .m_axi_wstrb,
      .m_axi_wlast,
      .m_axi_wvalid,
      .m_axi_wready,
      .m_axi_bid,
      .m_axi_bresp,
      .m_axi_bvalid,
      .m_axi_bready,
      .m_axi_arid,
      .m_axi_araddr,
      .m_axi_arlen,
      .m_axi_arsize,
      .m_axi_arburst,
      .m_axi_arvalid,
      .m_axi_arready,
      .m_axi_rid,
      .m_axi_rdata,
      .m_axi_rresp,
      .m_axi_rlast,
      .m_axi_rvalid,
      .m_axi_rready
    );
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
  end else if (USE_EXT_FB) begin : g_ext_frame_buffer
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
    assign m_axi_awid = '0;                      // the AXI4 master port idle
    assign m_axi_awaddr = '0;
    assign m_axi_awlen = '0;
    assign m_axi_awsize = '0;
    assign m_axi_awburst = '0;
    assign m_axi_awvalid = 1'b0;
    assign m_axi_wdata = '0;
    assign m_axi_wstrb = '0;
    assign m_axi_wlast = 1'b0;
    assign m_axi_wvalid = 1'b0;
    assign m_axi_bready = 1'b0;
    assign m_axi_arid = '0;
    assign m_axi_araddr = '0;
    assign m_axi_arlen = '0;
    assign m_axi_arsize = '0;
    assign m_axi_arburst = '0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready = 1'b0;
    wire unused_axi = &{1'b0, m_axi_awready, m_axi_wready, m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_arready,
                        m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, wbuf, rbuf, 1'b0};
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
    assign m_axi_awid = '0;                      // the AXI4 master port idle
    assign m_axi_awaddr = '0;
    assign m_axi_awlen = '0;
    assign m_axi_awsize = '0;
    assign m_axi_awburst = '0;
    assign m_axi_awvalid = 1'b0;
    assign m_axi_wdata = '0;
    assign m_axi_wstrb = '0;
    assign m_axi_wlast = 1'b0;
    assign m_axi_wvalid = 1'b0;
    assign m_axi_bready = 1'b0;
    assign m_axi_arid = '0;
    assign m_axi_araddr = '0;
    assign m_axi_arlen = '0;
    assign m_axi_arsize = '0;
    assign m_axi_arburst = '0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready = 1'b0;
    wire unused_axi = &{1'b0, m_axi_awready, m_axi_wready, m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_arready,
                        m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, wbuf, rbuf, 1'b0};
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
