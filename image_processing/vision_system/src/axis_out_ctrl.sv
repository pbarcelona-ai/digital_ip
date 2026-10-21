// ***************
// Filename: axis_out_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Output side of vision_system (version 2.0.0): generates the
//   output raster, the source position of every pixel (coord_gen), reads its
//   taps from the frame store and interpolates them (bilinear or bicubic),
//   as an AXI4-Stream video master with back-pressure. Golden model:
//   model/vision_system_model.py (correct(); tb/python).
//     - Taps: x0 = floor(sx), y0 = floor(sy) (sx, sy Q16.16); bilinear reads
//       x0 / x0 + 1 by y0 / y0 + 1, bicubic x0 - 1 .. x0 + 2 by y0 - 1 ..
//       y0 + 2; every tap is clamped into the frame (edge replication, as
//       OpenCV BORDER_REPLICATE), the fractions are sx[15:8] / sy[15:8]
//       (bilinear) or sx[15:0] / sy[15:0] (bicubic). Any frame size works.
//     - Frame store: a read request carries four addresses (fb_rd_en with
//       fb_rd_ready); the four words return in request order (fb_rd_valid),
//       any number of clocks later. Bilinear: one request per pixel;
//       bicubic: one per tap row (four per pixel).
//     - Flow control: at most CREDITS pixels are between the raster and the
//       output (a credit is returned when a pixel leaves on m_axis); every
//       FIFO holds CREDITS entries, so coord_gen, the store and the
//       interpolators never need to stall. Throughput - 1 pixel per clock
//       (bilinear with a store answering every clock), 1 per 4 clocks
//       (bicubic), 1 per coord_gen slow-path result (FISHEYE / PANORAMIC /
//       PERSPECTIVE).
//     - start_output begins a frame of img_width x img_height pixels (both at
//       least 1, as axi_lite_regs clamps them; taken only while idle, with
//       interp_mode for the whole frame); busy until
//       its last pixel has left, frame_out_done pulses then. cfg must stay
//       stable while busy.
//   Parameters: CREDITS (power of two, 8 .. 64; $error otherwise).
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none. Latency - the first pixel 33 clocks after
//   start_output (bilinear, fast models, a store answering the next clock;
//   measured), 52 (bicubic), about 73 / 92 with the slow models.
//   Errors - none (the credits keep every FIFO from overflowing).
// Date: 2026-10-21
module axis_out_ctrl #(
  parameter int COORD_W = barrel_pkg::COORD_W,
  parameter int ADDR_W  = barrel_pkg::ADDR_W,
  parameter int CREDITS = 64                     // pixels in flight: the FIFOs' depth (power of two, 8 .. 64)
) (
  input  logic                 clk,              // clock
  input  logic                 rst_n,            // synchronous, active low
  // control
  input  logic                 start_output,     // pulse: begin a frame (taken while idle)
  input  logic [COORD_W-1:0]   img_width,        // frame width, 1 .. (axi_lite_regs clamps it)
  input  logic [COORD_W-1:0]   img_height,       // frame height, 1 ..
  input  logic                 interp_mode,      // 0 bilinear, 1 bicubic (taken with start_output)
  output logic                 busy,             // a frame is being generated or is still leaving
  output logic                 frame_out_done,   // pulse: the frame's last pixel has left
  // calibration (distortion_model_pkg::calib_params_t, stable while busy)
  input  distortion_model_pkg::calib_params_t cfg,
  // frame store read port
  output logic                 fb_rd_en,         // a request taken (fb_rd_ready high)
  output logic [ADDR_W-1:0]    fb_rd_addr0,      // bilinear: (x0, y0); bicubic: (x0 - 1, row)
  output logic [ADDR_W-1:0]    fb_rd_addr1,      // bilinear: (x0 + 1, y0); bicubic: (x0, row)
  output logic [ADDR_W-1:0]    fb_rd_addr2,      // bilinear: (x0, y0 + 1); bicubic: (x0 + 1, row)
  output logic [ADDR_W-1:0]    fb_rd_addr3,      // bilinear: (x0 + 1, y0 + 1); bicubic: (x0 + 2, row)
  input  logic [barrel_pkg::PIX_W-1:0] fb_rd_data0,   // the words of a request, with fb_rd_valid
  input  logic [barrel_pkg::PIX_W-1:0] fb_rd_data1,
  input  logic [barrel_pkg::PIX_W-1:0] fb_rd_data2,
  input  logic [barrel_pkg::PIX_W-1:0] fb_rd_data3,
  input  logic                 fb_rd_ready,      // the store takes a request
  input  logic                 fb_rd_valid,      // one clock: a request's four words (in request order)
  // video out
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = barrel_pkg::PIX_W
  axis_if.master m_axis
);
  localparam int PW    = barrel_pkg::PIX_W;
  localparam int CNT_W = $clog2(CREDITS) + 1;
  if (CREDITS < 8 || CREDITS > 64 || (CREDITS & (CREDITS - 1)) != 0) begin : g_bad_credits
    $error("axis_out_ctrl: CREDITS must be a power of two, 8 .. 64");
  end
  assign m_axis.tkeep = '1;

  // ---------------- raster: one pixel per credit; the slow coord_gen path takes one request at a time
  logic                active, mode_f, issued_q;
  logic [COORD_W-1:0]  x_cnt, y_cnt;
  logic [CNT_W-1:0]    inflight;
  logic                cg_busy;
  wire  out_pop  = m_axis.tvalid && m_axis.tready;
  wire  slow     = (cfg.model_sel == distortion_model_pkg::MODEL_FISHEYE) ||
                   (cfg.model_sel == distortion_model_pkg::MODEL_PANORAMIC) ||
                   (cfg.model_sel == distortion_model_pkg::MODEL_PERSPECTIVE);
  wire  last_x   = (x_cnt == img_width - 1'b1);
  wire  last_y   = (y_cnt == img_height - 1'b1);
  wire  issue    = active && (inflight < CNT_W'(CREDITS)) && (!slow || (!cg_busy && !issued_q));
  logic [2*COORD_W-1:0] remaining;               // pixels of the frame still to leave
  logic                 counting;
  wire  start    = start_output && !busy && img_width != '0 && img_height != '0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 1'b0;
      mode_f <= 1'b0;
      issued_q <= 1'b0;
      x_cnt <= '0;
      y_cnt <= '0;
      inflight <= '0;
      remaining <= '0;
      counting <= 1'b0;
      frame_out_done <= 1'b0;
    end else begin
      issued_q <= issue;
      frame_out_done <= 1'b0;
      inflight <= inflight + CNT_W'(issue) - CNT_W'(out_pop);
      if (start) begin
        active <= 1'b1;
        mode_f <= interp_mode;
        x_cnt <= '0;
        y_cnt <= '0;
        remaining <= (2*COORD_W)'(img_width) * (2*COORD_W)'(img_height);
        counting <= 1'b1;
      end else if (issue) begin
        if (last_x) begin
          x_cnt <= '0;
          if (last_y) active <= 1'b0;
          else y_cnt <= y_cnt + 1'b1;
        end else x_cnt <= x_cnt + 1'b1;
      end
      if (counting && out_pop) begin
        if (remaining == 1) begin
          counting <= 1'b0;
          frame_out_done <= 1'b1;
        end
        remaining <= remaining - 1'b1;
      end
    end
  end
  assign busy = active || counting || inflight != '0;

  // tags of the issued pixels ({tlast, tuser}), in order, to the output
  logic [1:0]       tag_d;
  logic             tag_v, tag_rdy, res_v;
  logic [CNT_W-1:0] tag_lvl;
  fallthrough_fifo #(
    .WIDTH(2),
    .DEPTH(CREDITS)
  ) u_tags (
    .clk,
    .rst_n,
    .s_data_i({last_x, x_cnt == '0 && y_cnt == '0}),
    .s_valid_i(issue),
    .s_ready_o(tag_rdy),
    .m_data_o(tag_d),
    .m_valid_o(tag_v),
    .m_ready_i(res_v),
    .level_o(tag_lvl)
  );

  // ---------------- source position of every pixel
  logic               cg_valid;
  logic signed [31:0] cg_sx, cg_sy;
  coord_gen #(.COORD_W(COORD_W)) u_coord_gen (
    .clk,
    .rst_n,
    .cfg,
    .in_valid(issue),
    .in_x(x_cnt),
    .in_y(y_cnt),
    .out_valid(cg_valid),
    .out_sx_q16(cg_sx),
    .out_sy_q16(cg_sy),
    .busy(cg_busy)
  );
  logic [63:0]      cq_d;
  logic             cq_v, cq_rdy, cq_pop;
  logic [CNT_W-1:0] cq_lvl;
  fallthrough_fifo #(
    .WIDTH(64),
    .DEPTH(CREDITS)
  ) u_coords (
    .clk,
    .rst_n,
    .s_data_i({cg_sx, cg_sy}),
    .s_valid_i(cg_valid),
    .s_ready_o(cq_rdy),
    .m_data_o(cq_d),
    .m_valid_o(cq_v),
    .m_ready_i(cq_pop),
    .level_o(cq_lvl)
  );

  // ---------------- requests: P1 taps, P2 row bases, P3 the store requests (stalled by fb_rd_ready)
  function automatic logic [COORD_W-1:0] clampc(input logic signed [31:0] v, input logic [COORD_W-1:0] n);
    if (v < 0) clampc = '0;
    else if (v > $signed(32'(n)) - 32'sd1) clampc = n - 1'b1;
    else clampc = v[COORD_W-1:0];
  endfunction
  wire signed [31:0] q_sx = cq_d[63:32], q_sy = cq_d[31:0];
  wire signed [31:0] q_x0 = q_sx >>> 16, q_y0 = q_sy >>> 16;
  logic               v1, v2, v3;
  logic [COORD_W-1:0] xs1 [4], ys1 [4], xs2 [4], xs3 [4];
  logic [15:0]        tx1, ty1, tx2, ty2;
  logic [ADDR_W-1:0]  rb2 [4], rb3 [4];
  logic [1:0]         row3;
  wire  req_last = !mode_f || row3 == 2'd3;
  wire  accept   = v3 && fb_rd_ready;
  wire  en3      = !v3 || (accept && req_last);
  wire  en2      = !v2 || en3;
  wire  en1      = !v1 || en2;
  assign cq_pop = cq_v && en1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {v1, v2, v3} <= '0;
      row3 <= '0;
    end else begin
      if (en1) v1 <= cq_v;
      if (en2) v2 <= v1;
      if (en3) begin
        v3 <= v2;
        row3 <= '0;
      end else if (accept) row3 <= row3 + 1'b1;
    end
  end
  always_ff @(posedge clk) begin                 // data stages: not reset (qualified by v1 .. v3)
    if (en1) begin
      for (int i = 0; i < 4; i++) begin
        xs1[i] <= clampc(q_x0 - 32'sd1 + 32'(i), img_width);
        ys1[i] <= clampc(q_y0 - 32'sd1 + 32'(i), img_height);
      end
      tx1 <= q_sx[15:0];
      ty1 <= q_sy[15:0];
    end
    if (en2) begin
      for (int i = 0; i < 4; i++) begin
        rb2[i] <= ADDR_W'(ys1[i]) * ADDR_W'(img_width);
        xs2[i] <= xs1[i];
      end
      tx2 <= tx1;
      ty2 <= ty1;
    end
    if (en3) begin
      for (int i = 0; i < 4; i++) begin
        rb3[i] <= rb2[i];
        xs3[i] <= xs2[i];
      end
    end
  end
  // bilinear: rows y0 / y0 + 1 (taps 1, 2) by columns x0 / x0 + 1; bicubic: row row3 by columns 0 .. 3
  wire [ADDR_W-1:0] rba = mode_f ? rb3[row3] : rb3[1];
  wire [ADDR_W-1:0] rbb = mode_f ? rb3[row3] : rb3[2];
  assign fb_rd_en    = accept;
  assign fb_rd_addr0 = rba + ADDR_W'(mode_f ? xs3[0] : xs3[1]);
  assign fb_rd_addr1 = rba + ADDR_W'(mode_f ? xs3[1] : xs3[2]);
  assign fb_rd_addr2 = rbb + ADDR_W'(mode_f ? xs3[2] : xs3[1]);
  assign fb_rd_addr3 = rbb + ADDR_W'(mode_f ? xs3[3] : xs3[2]);

  // fractions of the requested pixels ({tx, ty}), in order, to the interpolators
  logic [31:0]      wq_d;
  logic             wq_v, wq_rdy, wq_pop;
  logic [CNT_W-1:0] wq_lvl;
  fallthrough_fifo #(
    .WIDTH(32),
    .DEPTH(CREDITS)
  ) u_fracs (
    .clk,
    .rst_n,
    .s_data_i({tx2, ty2}),
    .s_valid_i(v2 && en3),
    .s_ready_o(wq_rdy),
    .m_data_o(wq_d),
    .m_valid_o(wq_v),
    .m_ready_i(wq_pop),
    .level_o(wq_lvl)
  );

  // ---------------- responses: bilinear at once, bicubic after its four rows
  logic [1:0]    rrow;
  logic [PW-1:0] tap [4][4];
  logic          bc_go;
  logic [15:0]   bc_tx, bc_ty;
  wire  rsp_bl  = fb_rd_valid && !mode_f;
  wire  rsp_bc4 = fb_rd_valid && mode_f && rrow == 2'd3;
  assign wq_pop = rsp_bl || rsp_bc4;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rrow <= '0;
      bc_go <= 1'b0;
    end else begin
      bc_go <= rsp_bc4;
      if (fb_rd_valid && mode_f) rrow <= rrow + 1'b1;
    end
  end
  always_ff @(posedge clk) begin                 // taps and fractions: not reset (qualified by bc_go)
    if (fb_rd_valid && mode_f) begin
      tap[rrow][0] <= fb_rd_data0;
      tap[rrow][1] <= fb_rd_data1;
      tap[rrow][2] <= fb_rd_data2;
      tap[rrow][3] <= fb_rd_data3;
    end
    if (rsp_bc4) begin
      bc_tx <= wq_d[31:16];
      bc_ty <= wq_d[15:0];
    end
  end
  logic          bl_v, bc_v;
  logic [PW-1:0] bl_pix, bc_pix;
  bilinear u_bilinear (
    .clk,
    .rst_n,
    .valid_in(rsp_bl),
    .fx(wq_d[31:24]),
    .fy(wq_d[15:8]),
    .tl(fb_rd_data0),
    .tr(fb_rd_data1),
    .bl(fb_rd_data2),
    .br(fb_rd_data3),
    .valid_out(bl_v),
    .pixel_out(bl_pix)
  );
  bicubic u_bicubic (
    .clk,
    .rst_n,
    .valid_in(bc_go),
    .tx_q16({16'd0, bc_tx}),
    .ty_q16({16'd0, bc_ty}),
    .p00(tap[0][0]),
    .p01(tap[0][1]),
    .p02(tap[0][2]),
    .p03(tap[0][3]),
    .p10(tap[1][0]),
    .p11(tap[1][1]),
    .p12(tap[1][2]),
    .p13(tap[1][3]),
    .p20(tap[2][0]),
    .p21(tap[2][1]),
    .p22(tap[2][2]),
    .p23(tap[2][3]),
    .p30(tap[3][0]),
    .p31(tap[3][1]),
    .p32(tap[3][2]),
    .p33(tap[3][3]),
    .valid_out(bc_v),
    .pixel_out(bc_pix)
  );

  // ---------------- output: the interpolated pixel with its tags (space reserved by the credits)
  assign res_v = bl_v || bc_v;
  logic [PW+1:0]    of_d;
  logic             of_rdy;
  logic [CNT_W-1:0] of_lvl;
  fallthrough_fifo #(
    .WIDTH(PW + 2),
    .DEPTH(CREDITS)
  ) u_out (
    .clk,
    .rst_n,
    .s_data_i({tag_d, mode_f ? bc_pix : bl_pix}),
    .s_valid_i(res_v),
    .s_ready_o(of_rdy),
    .m_data_o(of_d),
    .m_valid_o(m_axis.tvalid),
    .m_ready_i(m_axis.tready),
    .level_o(of_lvl)
  );
  assign m_axis.tdata = of_d[PW-1:0];
  assign m_axis.tuser = of_d[PW];
  assign m_axis.tlast = of_d[PW+1];
  // not used: the FIFOs' levels and ready flags (the credits keep every FIFO from filling), the tag and
  // fraction FIFOs' valid flags (a result always has its tag and fractions)
  wire unused_ok = &{1'b0, tag_lvl, cq_lvl, wq_lvl, of_lvl, tag_rdy, cq_rdy, wq_rdy, of_rdy, tag_v, wq_v, 1'b0};
endmodule
