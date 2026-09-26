// ***************
// Filename: scaler_edge_directed.sv
// Author: Paul Barcelona
// Description: Edge-directed (triangulation) scaler IP.
//   For each output pixel the 2x2 source cell p00 p01 / p10 p11 gives
//     d1 = sum_c |p00-p11|  (activity along the "\" diagonal)
//     d2 = sum_c |p01-p10|  (activity along the "/" diagonal)
//   d1 + THRESH < d2 : edge along "\" - split the cell on p00-p11 and
//                      interpolate inside the triangle holding the point
//   d2 + THRESH < d1 : split on p01-p10 likewise
//   otherwise        : plain bilinear
//   Weights are integers in units of ONE^2 (ONE = 2^PHASE_BITS), so
//     out = (w00*p00 + w01*p01 + w10*p10 + w11*p11 + ONE^2/2) >> 2*PB
//   This removes most bilinear stair-stepping on diagonal edges at any
//   scale factor.
//   IP registers: 0x040 THRESH [15:0], 0x044 EDGE_CTRL [0] EDGE_EN
//   (0 = identical to scaler_bilinear).
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame (default
//   and PINGPONG = 1) or a few input lines (LINE_BUF = 1).
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_edge_directed #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int PHASE_BITS = 8,        // sub-pixel phase resolution
  parameter int PINGPONG = 0,          // 1: double frame buffer (capture while generating)
  parameter int LINE_BUF = 0,          // 1: line-buffer mode (latency of a few lines;
                                       //    MAX_H is then not a limit, STEP_Y >= 0)
  localparam int PIX_W   = CHANNELS * COMP_W   // bits per pixel
)(
  input  logic              clk,            // clock
  input  logic              rst_n,          // async reset, active low
  // AXI4-Lite control slave (register map in the file header)
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
  // AXI4-Stream video in (raster order)
  input  logic [PIX_W-1:0]  s_axis_tdata,   // pixel, component 0 in LSBs
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,  // low while generating
  input  logic              s_axis_tuser,   // start of frame
  input  logic              s_axis_tlast,   // end of line
  // AXI4-Stream video out (raster order)
  output logic [PIX_W-1:0]  m_axis_tdata,   // scaled pixel
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,  // back-pressure stalls all
  output logic              m_axis_tuser,   // start of frame
  output logic              m_axis_tlast    // end of line
);

  // Identification: IP_ID = ASCII "EDGE";
  // CAPS = {PHASE_BITS, COMP_W, CHANNELS, taps}
  localparam logic [31:0] IP_ID = 32'h4544_4745;             // "EDGE"
  localparam logic [31:0] CAPS  = {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'd2};
  localparam int          ONE   = 1 << PHASE_BITS;
  localparam int          WW    = 2 * PHASE_BITS + 1;       // weight width
  localparam int          DW    = COMP_W + $clog2(CHANNELS) + 1;  // |diff| sum

  logic [31:0] ext_rdata;

  // ---------------------------------------------------------------- buffering
  // Frame store organisation (see scaler_ctrl / banked_framebuf):
  //   default   : one frame buffer (input stalls while a frame is generated)
  //   PINGPONG  : two frame buffers, capture of frame N+1 overlaps output of N
  //   LINE_BUF  : ring of LB_ROWS lines, output starts after a few input lines
  function automatic int pow2ceil_i(input int v);
    int r = 1;
    while (r < v) r = r * 2;
    return r;
  endfunction
  localparam int WIN_T   = 2;                            // window size
  localparam int NBUF    = PINGPONG ? 2 : 1;
  localparam int LB_ROWS = LINE_BUF ? pow2ceil_i(WIN_T + 2 < 4 ? 4 : WIN_T + 2) : 0;
  initial if (PINGPONG && LINE_BUF)
    $fatal(1, "scaler_edge_directed: PINGPONG and LINE_BUF are mutually exclusive");

  // ---------------------------------------------------------------- control
  // scaler_ctrl implements the AXI-Lite common registers, captures the
  // input frame into the frame buffer and sequences capture/generate.
  logic               fb_we;           // frame buffer write port
  logic [15:0]        fb_wx, fb_wy;
  logic [PIX_W-1:0]   fb_wdata;
  logic               gen_start, gen_done;  // frame captured / frame sent
  logic               fb_wbuf, gen_buf;     // ping-pong buffer selects
  logic               lb_hold;              // line buffer: source rows missing
  logic signed [31:0] d_nxt_y, a_y;         // y of next / stage-A pixel
  logic [15:0]        in_w, in_h, out_w, out_h;   // IN_SIZE / OUT_SIZE
  logic [31:0]        step_x, step_y;  // STEP_X/Y   (u16.16)
  logic signed [31:0] offs_x, offs_y;  // OFFS_X/Y   (s16.16)
  logic               ext_wr, ext_rd;  // IP register bus (>= 0x040)
  logic [ADDR_W-1:0]  ext_waddr, ext_raddr;
  logic [31:0]        ext_wdata;

  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(IP_ID), .CAPS(CAPS), .NBUF(NBUF), .LB_ROWS(LB_ROWS),
                .LB_TAPS(WIN_T), .LB_CTR(0), .LB_RND(1 << (16 - PHASE_BITS - 1))) u_ctrl (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
    .fb_we, .fb_wx, .fb_wy, .fb_wdata,
    .fb_wbuf, .gen_buf, .gen_start, .gen_done,
    .lb_nxt_y(d_nxt_y), .lb_nxt_v(d_busy), .lb_o_y(d_y), .lb_o_v(d_valid),
    .lb_a_y(a_y), .lb_a_v(v_q[0]), .lb_hold,
    .cfg_in_w(in_w), .cfg_in_h(in_h), .cfg_out_w(out_w), .cfg_out_h(out_h),
    .cfg_step_x(step_x), .cfg_step_y(step_y), .cfg_offs_x(offs_x), .cfg_offs_y(offs_y),
    .ext_wr, .ext_waddr, .ext_wdata, .ext_rd, .ext_raddr, .ext_rdata(ext_rdata)
  );

  // ---------------------------------------------------------------- IP registers
  logic [15:0] thresh;     // THRESH    (0x040)
  logic        edge_en;    // EDGE_CTRL (0x044) bit 0
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      thresh    <= 16'd16;
      edge_en   <= 1'b1;
      ext_rdata <= '0;
    end else begin
      // IP register write
      if (ext_wr) begin
        case (ext_waddr[7:0])
          8'h40: thresh  <= ext_wdata[15:0];
          8'h44: edge_en <= ext_wdata[0];
          default: ;
        endcase
      end
      // IP register read (registered, 1-cycle latency)
      if (ext_rd) begin
        case (ext_raddr[7:0])
          8'h40:   ext_rdata <= {16'd0, thresh};
          8'h44:   ext_rdata <= {31'd0, edge_en};
          default: ext_rdata <= '0;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------- pipeline
  // Global pipeline advance: every stage moves forward unless the output
  // register holds a beat the sink has not accepted yet.
  wire adv = !m_axis_tvalid || m_axis_tready;

  logic               d_valid, d_sof, d_eol, d_eof, d_busy;
  logic signed [31:0] d_x, d_y;

  // DDA: raster scan of the output, source coordinate per pixel
  scaler_dda u_dda (
    .clk, .rst_n, .start(gen_start), .adv, .hold(lb_hold), .nxt_y(d_nxt_y),
    .out_w, .out_h, .step_x, .step_y, .offs_x, .offs_y,
    .busy(d_busy), .o_valid(d_valid), .o_x(d_x), .o_y(d_y),
    .o_sof(d_sof), .o_eol(d_eol), .o_eof(d_eof)
  );

  // Round the source coordinate to the PHASE_BITS grid: integer part =
  // window position, top PHASE_BITS fraction bits = sub-pixel phase.
  localparam logic signed [31:0] RND = 32'sd1 <<< (16 - PHASE_BITS - 1);
  wire signed [31:0]     rx = d_x + RND;
  wire signed [31:0]     ry = d_y + RND;
  wire signed [17:0]     ix = 18'(rx >>> 16);
  wire signed [17:0]     iy = 18'(ry >>> 16);
  wire [PHASE_BITS-1:0]  fx = rx[15 -: PHASE_BITS];
  wire [PHASE_BITS-1:0]  fy = ry[15 -: PHASE_BITS];

  logic [4*PIX_W-1:0] win;
  banked_framebuf #(.PIX_W(PIX_W), .TAPS(2), .MAX_W(MAX_W), .MAX_H(MAX_H),
                  .NBUF(NBUF), .RING(LB_ROWS)) u_fb (
    .clk,
    .wr_en(fb_we), .wr_x(fb_wx), .wr_y(fb_wy), .wr_data(fb_wdata), .wr_buf(fb_wbuf),
    .rd_adv(adv), .rd_buf(gen_buf), .rd_x0(ix), .rd_y0(iy), .img_w(in_w), .img_h(in_h),
    .rd_win(win)
  );

  // Pipeline registers: [0] stage A, [1] stage B (window), [2] stage 3
  logic [2:0]            v_q;
  logic [2:0]            f_q [3];
  logic [PHASE_BITS-1:0] fx_q [2], fy_q [2];
  logic                  m_eof;

  // ---- stage 3 (comb): edge decision and weights
  // d1/d2 measure the activity along the two diagonals, summed over all
  // components so that every component uses the same triangulation.
  // The chosen case yields four integer weights that sum to ONE^2.
  logic [DW-1:0] d1, d2;
  logic [WW-1:0] w00_c, w01_c, w10_c, w11_c;
  always_comb begin
    int a, b, x, y, one;
    // diagonal activity, summed over the components
    d1 = '0; d2 = '0;
    for (int c = 0; c < CHANNELS; c++) begin
      int p00, p01, p10, p11;
      p00 = int'(win[(0*PIX_W) + c*COMP_W +: COMP_W]);
      p01 = int'(win[(1*PIX_W) + c*COMP_W +: COMP_W]);
      p10 = int'(win[(2*PIX_W) + c*COMP_W +: COMP_W]);
      p11 = int'(win[(3*PIX_W) + c*COMP_W +: COMP_W]);
      d1 = d1 + DW'((p00 > p11) ? p00 - p11 : p11 - p00);
      d2 = d2 + DW'((p01 > p10) ? p01 - p10 : p10 - p01);
    end
    // sample position inside the cell, 0 .. ONE-1 on each axis
    x = int'(fx_q[1]); y = int'(fy_q[1]); one = ONE;
    if (edge_en && (int'(d1) + int'(thresh) < int'(d2))) begin
      // edge along p00-p11 : triangles (p00,p01,p11) / (p00,p10,p11)
      if (x >= y) begin                // upper-right triangle
        w00_c = WW'((one - x) * one); w01_c = WW'((x - y) * one);
        w10_c = '0;                   w11_c = WW'(y * one);
      end else begin                   // lower-left triangle
        w00_c = WW'((one - y) * one); w01_c = '0;
        w10_c = WW'((y - x) * one);   w11_c = WW'(x * one);
      end
    end else if (edge_en && (int'(d2) + int'(thresh) < int'(d1))) begin
      // edge along p01-p10 : triangles (p00,p01,p10) / (p01,p10,p11)
      if (x + y <= one) begin          // upper-left triangle
        w00_c = WW'((one - x - y) * one); w01_c = WW'(x * one);
        w10_c = WW'(y * one);             w11_c = '0;
      end else begin                   // lower-right triangle
        w00_c = '0;                       w01_c = WW'((one - y) * one);
        w10_c = WW'((one - x) * one);     w11_c = WW'((x + y - one) * one);
      end
    end else begin
      // no dominant diagonal: bilinear weights
      w00_c = WW'((one - x) * (one - y)); w01_c = WW'(x * (one - y));
      w10_c = WW'((one - x) * y);         w11_c = WW'(x * y);
    end
  end

  // stage-3 registers: weights and the window they apply to
  logic [WW-1:0]      w00_q, w01_q, w10_q, w11_q;
  logic [4*PIX_W-1:0] win_q;

  // ---- stage 4 (comb): weighted sum with rounding (convex weights, so
  // no clamping is needed)
  localparam int SW = COMP_W + WW + 2;
  logic [PIX_W-1:0] out_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [SW-1:0] s;
      s = SW'(win_q[(0*PIX_W) + c*COMP_W +: COMP_W]) * SW'(w00_q)
        + SW'(win_q[(1*PIX_W) + c*COMP_W +: COMP_W]) * SW'(w01_q)
        + SW'(win_q[(2*PIX_W) + c*COMP_W +: COMP_W]) * SW'(w10_q)
        + SW'(win_q[(3*PIX_W) + c*COMP_W +: COMP_W]) * SW'(w11_q)
        + SW'(ONE * ONE / 2);
      out_c[c*COMP_W +: COMP_W] = COMP_W'(s >> (2 * PHASE_BITS));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q           <= '0;
      for (int k = 0; k < 3; k++) f_q[k] <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= '0;
      m_axis_tuser  <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_eof         <= 1'b0;
    end else if (gen_start) begin
      v_q           <= '0;           // flush at the start of a frame
    end else if (adv) begin
      // valid/flags follow the data through stages A, B and 3; the
      // result of stage 4 is registered straight into the output
      v_q[0] <= d_valid;
      f_q[0] <= {d_eof, d_eol, d_sof};
      for (int k = 1; k < 3; k++) begin
        v_q[k] <= v_q[k-1];
        f_q[k] <= f_q[k-1];
      end
      m_axis_tvalid <= v_q[2];
      m_axis_tdata  <= out_c;
      {m_eof, m_axis_tlast, m_axis_tuser} <= f_q[2];
    end
  end

  // Data path registers (no reset needed)
  always_ff @(posedge clk) begin
    if (adv) begin
      fx_q[0] <= fx;  fx_q[1] <= fx_q[0];
      fy_q[0] <= fy;  fy_q[1] <= fy_q[0];
      w00_q <= w00_c; w01_q <= w01_c; w10_q <= w10_c; w11_q <= w11_c;
      win_q <= win;
    end
  end

  // Frame finished when the last output pixel is accepted by the sink
  // y of the pixel in read stage A (line-buffer flow control)
  always_ff @(posedge clk) if (adv) a_y <= d_y;

  assign gen_done = m_axis_tvalid && m_axis_tready && m_eof;

endmodule
