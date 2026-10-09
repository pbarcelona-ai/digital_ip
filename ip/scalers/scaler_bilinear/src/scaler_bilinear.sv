// ***************
// Filename: scaler_bilinear.sv
// Author: FPGA Cores 4 U
// Description: Bilinear (2x2) image scaler IP.
//   The 16.16 source coordinate s is rounded to PB = PHASE_BITS bits:
//     s_r = s + 2^(15-PB); i = s_r >>> 16; f = s_r[15 -: PB]
//   With ONE = 2^PHASE_BITS and taps p00 p01 / p10 p11 at (i, i+1):
//     top = p00*(ONE-fx) + p01*fx
//     bot = p10*(ONE-fx) + p11*fx
//     out = (top*(ONE-fy) + bot*fy + ONE^2/2) >> (2*PHASE_BITS)
//   Weights are computed in hardware; no coefficient tables.
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame (default
//   and PINGPONG = 1) or a few input lines (LINE_BUF = 1).
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_bilinear #(
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

  // Identification: IP_ID = ASCII "BLIN";
  // CAPS = {PHASE_BITS, COMP_W, CHANNELS, taps}
  localparam logic [31:0] IP_ID = 32'h424C_494E;             // "BLIN"
  localparam logic [31:0] CAPS  = {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'd2};
  localparam int          ONE   = 1 << PHASE_BITS;         // weight 1.0

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
    $fatal(1, "scaler_bilinear: PINGPONG and LINE_BUF are mutually exclusive");

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

  // ---------------------------------------------------------------- pipeline
  // Global pipeline advance: every stage moves forward unless the output
  // register holds a beat the sink has not accepted yet.
  wire adv = !m_axis_tvalid || m_axis_tready;

  // stage 0 : DDA - source coordinate (s16.16) of each output pixel
  logic               d_valid, d_sof, d_eol, d_eof, d_busy;
  logic signed [31:0] d_x, d_y;

  // DDA: raster scan of the output, source coordinate per pixel
  scaler_dda u_dda (
    .clk,
    .rst_n,
    .start(gen_start),
    .adv,
    .hold(lb_hold),
    .nxt_y(d_nxt_y),
    .out_w,
    .out_h,
    .step_x,
    .step_y,
    .offs_x,
    .offs_y,
    .busy(d_busy),
    .o_valid(d_valid),
    .o_x(d_x),
    .o_y(d_y),
    .o_sof(d_sof),
    .o_eol(d_eol),
    .o_eof(d_eof)
  );

  // Round the source coordinate to the PHASE_BITS grid: integer part =
  // window position, top PHASE_BITS fraction bits = sub-pixel phase.
  localparam logic signed [31:0] RND = 32'sd1 <<< (16 - PHASE_BITS - 1);
  wire signed [31:0]     rx = d_x + RND;
  wire signed [31:0]     ry = d_y + RND;
  wire signed [17:0]     ix = 18'(rx >>> 16);      // left tap column
  wire signed [17:0]     iy = 18'(ry >>> 16);      // top tap row
  wire [PHASE_BITS-1:0]  fx = rx[15 -: PHASE_BITS]; // x weight of p01
  wire [PHASE_BITS-1:0]  fy = ry[15 -: PHASE_BITS]; // y weight of row 1

  // stages 1-2 : 2x2 window p00 p01 / p10 p11 from the frame buffer
  logic [4*PIX_W-1:0] win;
  banked_framebuf #(.PIX_W(PIX_W), .TAPS(2), .MAX_W(MAX_W), .MAX_H(MAX_H),
                  .NBUF(NBUF), .RING(LB_ROWS)) u_fb (
    .clk,
    .wr_en(fb_we),
    .wr_x(fb_wx),
    .wr_y(fb_wy),
    .wr_data(fb_wdata),
    .wr_buf(fb_wbuf),
    .rd_adv(adv),
    .rd_buf(gen_buf),
    .rd_x0(ix),
    .rd_y0(iy),
    .img_w(in_w),
    .img_h(in_h),
    .rd_win(win)
  );

  localparam int HW = COMP_W + PHASE_BITS + 1;   // horizontal sum width
  localparam int VW = HW + PHASE_BITS + 1;       // vertical sum width

  // Pipeline (every register advances with adv; valid/flags follow the data)
  //   A    window origin / phases        (banked_framebuf stage A)
  //   B    RAM data                      (banked_framebuf stage B)
  //   W    window after the tap multiplexer
  //   M1   horizontal products  p * (ONE - fx), p * fx      (DSP48)
  //   S1   top = p00*(ONE-fx) + p01*fx, bot likewise
  //   M2   vertical products    top * (ONE - fy), bot * fy  (DSP48)
  //   out  (sum + ONE^2/2) >> 2*PHASE_BITS -> m_axis
  // One multiply or one add per stage; bit-identical to the single-cycle
  // form (exact products, same accumulator widths). The result is always
  // within [0, 2^COMP_W-1] because the weights are convex.
  localparam int NST = 6;
  logic [NST-1:0]        v_q;                    // valid per stage
  logic [2:0]            f_q [NST];              // {eof, eol, sof}
  logic [PHASE_BITS:0]   wx0, wx1, wy0_d [3], wy1_d [3];   // weights ONE-f, f
  logic [PHASE_BITS-1:0] fx_q [2], fy_q [2];     // phases A, B
  logic [4*PIX_W-1:0]    win_q;                  // W
  logic [HW-1:0]         ph_q [CHANNELS][4];     // M1: p00a p01b p10a p11b
  logic [HW-1:0]         top_q [CHANNELS], bot_q [CHANNELS];  // S1
  logic [VW-1:0]         pv_q [CHANNELS][2];     // M2
  logic                  m_eof;

  logic [PIX_W-1:0] out_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [VW-1:0] s;
      s = pv_q[c][0] + pv_q[c][1] + VW'(ONE * ONE / 2);
      out_c[c*COMP_W +: COMP_W] = COMP_W'(s >> (2 * PHASE_BITS));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q           <= '0;
      for (int k = 0; k < NST; k++) f_q[k] <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= '0;
      m_axis_tuser  <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_eof         <= 1'b0;
    end else if (gen_start) begin
      v_q           <= '0;           // flush at the start of a frame
    end else if (adv) begin
      v_q[0] <= d_valid;
      f_q[0] <= {d_eof, d_eol, d_sof};
      for (int k = 1; k < NST; k++) begin
        v_q[k] <= v_q[k-1];
        f_q[k] <= f_q[k-1];
      end
      m_axis_tvalid <= v_q[NST-1];
      m_axis_tdata  <= out_c;
      {m_eof, m_axis_tlast, m_axis_tuser} <= f_q[NST-1];
    end
  end

  // Data path registers (no reset needed)
  always_ff @(posedge clk) begin
    if (adv) begin
      fx_q[0] <= fx; // A, B
      fx_q[1] <= fx_q[0];
      fy_q[0] <= fy;
      fy_q[1] <= fy_q[0];
      win_q <= win;                                               // W
      wx0   <= (PHASE_BITS+1)'(ONE) - (PHASE_BITS+1)'(fx_q[1]);
      wx1   <= (PHASE_BITS+1)'(fx_q[1]);
      wy0_d[0] <= (PHASE_BITS+1)'(ONE) - (PHASE_BITS+1)'(fy_q[1]);
      wy1_d[0] <= (PHASE_BITS+1)'(fy_q[1]);
      for (int d = 1; d < 3; d++) begin
        wy0_d[d] <= wy0_d[d-1];
        wy1_d[d] <= wy1_d[d-1];
      end
      for (int c = 0; c < CHANNELS; c++) begin
        ph_q[c][0] <= HW'(win_q[(0*PIX_W) + c*COMP_W +: COMP_W]) * HW'(wx0);   // M1
        ph_q[c][1] <= HW'(win_q[(1*PIX_W) + c*COMP_W +: COMP_W]) * HW'(wx1);
        ph_q[c][2] <= HW'(win_q[(2*PIX_W) + c*COMP_W +: COMP_W]) * HW'(wx0);
        ph_q[c][3] <= HW'(win_q[(3*PIX_W) + c*COMP_W +: COMP_W]) * HW'(wx1);
        top_q[c]   <= ph_q[c][0] + ph_q[c][1];                                 // S1
        bot_q[c]   <= ph_q[c][2] + ph_q[c][3];
        pv_q[c][0] <= VW'(top_q[c]) * VW'(wy0_d[2]);                           // M2
        pv_q[c][1] <= VW'(bot_q[c]) * VW'(wy1_d[2]);
      end
    end
  end

  // Frame finished when the last output pixel is accepted by the sink
  // y of the pixel in read stage A (line-buffer flow control)
  always_ff @(posedge clk) if (adv) a_y <= d_y;

  assign gen_done = m_axis_tvalid && m_axis_tready && m_eof;

  // Control, registers and frame buffers. Instantiated last so every
  // signal it connects to is declared above it.
  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(IP_ID), .CAPS(CAPS), .NBUF(NBUF), .LB_ROWS(LB_ROWS),
                .LB_TAPS(WIN_T), .LB_CTR(0), .LB_RND(1 << (16 - PHASE_BITS - 1))) u_ctrl (
    .clk,
    .rst_n,
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
    .s_axis_tdata,
    .s_axis_tvalid,
    .s_axis_tready,
    .s_axis_tuser,
    .s_axis_tlast,
    .fb_we,
    .fb_wx,
    .fb_wy,
    .fb_wdata,
    .fb_wbuf,
    .gen_buf,
    .gen_start,
    .gen_done,
    .lb_nxt_y(d_nxt_y),
    .lb_nxt_v(d_busy),
    .lb_o_y(d_y),
    .lb_o_v(d_valid),
    .lb_a_y(a_y),
    .lb_a_v(v_q[0]),
    .lb_hold,
    .cfg_in_w(in_w),
    .cfg_in_h(in_h),
    .cfg_out_w(out_w),
    .cfg_out_h(out_h),
    .cfg_step_x(step_x),
    .cfg_step_y(step_y),
    .cfg_offs_x(offs_x),
    .cfg_offs_y(offs_y),
    .ext_wr,
    .ext_waddr,
    .ext_wdata,
    .ext_rd,
    .ext_raddr,
    .ext_rdata(32'd0)
  );
endmodule
