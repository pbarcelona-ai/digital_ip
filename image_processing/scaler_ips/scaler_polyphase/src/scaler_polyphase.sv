// ***************
// Filename: scaler_polyphase.sv
// Author: Paul Barcelona
// Description: Generic separable polyphase FIR scaler.
//   TAPS x TAPS kernel (even TAPS, 2..16) with programmable coefficient
//   tables. Engine of scaler_bicubic (4 taps) and scaler_lanczos (6 taps);
//   also usable directly, e.g. 8-12 taps for anti-aliased downscaling.
//   Source coordinate s (16.16) is rounded to PHASE_BITS fraction:
//     s_r = s + 2^(15-PHASE_BITS); i = s_r >>> 16; p = s_r[15 -: PB]
//   Window origin x0 = i - (TAPS/2 - 1), clamp-to-edge. With F=COEF_FRAC:
//     vertical   v_k = (sum_j CV[py][j]*in[y0+j][x0+k] + 2^(F-1)) >>> F
//     horizontal out = clamp((sum_k CH[px][k]*v_k + 2^(F-1)) >>> F)
//   IP registers:
//     0x040 COEF_INFO (RO) TAPS, PHASE_BITS, COEF_W, COEF_FRAC
//     0x1000 + 4*(16*phase + tap)  horizontal coefficients (RW, signed)
//     0x2000 + 4*(16*phase + tap)  vertical coefficients   (RW, signed)
//   Tables start as bilinear weights (initial block); update them only
//   while idle. See docs/coefficient_derivation.md.
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 output pixel/clock. Latency: one input frame (default
//   and PINGPONG = 1) or a few input lines (LINE_BUF = 1).
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_polyphase #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int TAPS       = 4,        // kernel size, even, 2..16
  parameter int PHASE_BITS = 6,        // log2(number of filter phases)
  parameter int COEF_W     = 16,       // coefficient width (signed)
  parameter int COEF_FRAC  = 14,       // coefficient fraction bits
  parameter logic [31:0] IP_ID = 32'h504F_4C59,              // "POLY"
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

  localparam int          PHASES = 1 << PHASE_BITS;           // filter phases
  localparam int          CTR    = (TAPS - 1) / 2;          // tap at integer position
  localparam logic [31:0] CAPS   = {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'(TAPS)};
  logic               d_valid, d_sof, d_eol, d_eof, d_busy;
  logic signed [31:0] d_x, d_y;
  // Arithmetic widths (sized so that no intermediate can overflow)
  localparam int LT  = $clog2(TAPS);
  localparam int AW1 = COMP_W + 1 + COEF_W + LT + 1;      // vertical accumulator
  localparam int VW  = COMP_W + LT + 3;                   // vertical result
  localparam int AW2 = VW + COEF_W + LT + 1;              // horizontal accumulator

  localparam int PV  = COMP_W + 1 + COEF_W;             // vertical product (exact)
  localparam int PH  = VW + COEF_W;                       // horizontal product (exact)
  localparam int NP  = 1 << LT;                           // TAPS padded to 2^LT
  localparam int LV  = LT;                                // adder-tree levels
  localparam int NST = 4 + LV + 1 + 1 + LV;              // stages before m_axis
  logic [NST-1:0]           v_q;                         // valid per stage


  // Elaboration-time parameter checks
  initial begin
    if (TAPS < 2 || TAPS > 16 || (TAPS % 2) != 0)
      $fatal(1, "scaler_polyphase: TAPS must be even and in 2..16");
    if (PHASE_BITS < 1 || PHASE_BITS > 6)
      $fatal(1, "scaler_polyphase: PHASE_BITS must be 1..6");
    if (ADDR_W < 14)
      $fatal(1, "scaler_polyphase: ADDR_W must be >= 14");
  end

  logic [31:0] ext_rdata;   // IP register read data (to scaler_ctrl)

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
  localparam int WIN_T   = TAPS;                            // window size
  localparam int NBUF    = PINGPONG ? 2 : 1;
  localparam int LB_ROWS = LINE_BUF ? pow2ceil_i(WIN_T + 2 < 4 ? 4 : WIN_T + 2) : 0;
  initial if (PINGPONG && LINE_BUF)
    $fatal(1, "scaler_polyphase: PINGPONG and LINE_BUF are mutually exclusive");

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
                .LB_TAPS(WIN_T), .LB_CTR((TAPS - 1) / 2), .LB_RND(1 << (16 - PHASE_BITS - 1))) u_ctrl (
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

  // ---------------------------------------------------------------- coefficient tables
  // coef_h[phase][tap] / coef_v[phase][tap], written over AXI-Lite. Each
  // phase row is read in full every clock, so the tables are kept as
  // register arrays (distributed RAM on FPGAs).
  logic signed [COEF_W-1:0] coef_h [PHASES][TAPS];
  logic signed [COEF_W-1:0] coef_v [PHASES][TAPS];

  // Power-up content: bilinear weights on the two centre taps, so the IP
  // produces a sensible image before the tables are programmed.
  initial begin
    for (int p = 0; p < PHASES; p++)
      for (int t = 0; t < TAPS; t++) begin
        coef_h[p][t] = (t == CTR)     ? COEF_W'(((PHASES - p) << COEF_FRAC) / PHASES) :
                       (t == CTR + 1) ? COEF_W'((p << COEF_FRAC) / PHASES) : '0;
        coef_v[p][t] = coef_h[p][t];
      end
  end

  // Table address decode: 0x1000 (H) / 0x2000 (V) + 4*(16*phase + tap)
  wire [5:0] w_ph  = ext_waddr[11:6];
  wire [3:0] w_tap = ext_waddr[5:2];
  wire [5:0] r_ph  = ext_raddr[11:6];
  wire [3:0] r_tap = ext_raddr[5:2];

  // Coefficient writes (addresses outside the tables are ignored)
  always_ff @(posedge clk) begin
    if (ext_wr && w_ph < PHASES && w_tap < TAPS) begin
      if (ext_waddr[13:12] == 2'd1) coef_h[w_ph][w_tap] <= ext_wdata[COEF_W-1:0];
      if (ext_waddr[13:12] == 2'd2) coef_v[w_ph][w_tap] <= ext_wdata[COEF_W-1:0];
    end
  end

  // IP register reads: COEF_INFO or a sign-extended coefficient
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ext_rdata <= '0;
    else if (ext_rd) begin
      ext_rdata <= '0;
      if (ext_raddr[13:0] == 14'h40)
        ext_rdata <= {8'(COEF_FRAC), 8'(COEF_W), 8'(PHASE_BITS), 8'(TAPS)};
      else if (r_ph < PHASES && r_tap < TAPS) begin
        if (ext_raddr[13:12] == 2'd1) ext_rdata <= 32'(coef_h[r_ph][r_tap]);
        if (ext_raddr[13:12] == 2'd2) ext_rdata <= 32'(coef_v[r_ph][r_tap]);
      end
    end
  end

  // ---------------------------------------------------------------- pipeline
  // Global pipeline advance: every stage moves forward unless the output
  // register holds a beat the sink has not accepted yet.
  wire adv = !m_axis_tvalid || m_axis_tready;

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
  wire signed [17:0]     x0 = 18'(rx >>> 16) - 18'(CTR);  // window left
  wire signed [17:0]     y0 = 18'(ry >>> 16) - 18'(CTR);  // window top
  wire [PHASE_BITS-1:0]  px = rx[15 -: PHASE_BITS];        // x phase
  wire [PHASE_BITS-1:0]  py = ry[15 -: PHASE_BITS];        // y phase

  // stages A-B : TAPS x TAPS window from the banked frame buffer

  logic [TAPS*TAPS*PIX_W-1:0] win;
  banked_framebuf #(.PIX_W(PIX_W), .TAPS(TAPS), .MAX_W(MAX_W), .MAX_H(MAX_H),
                  .NBUF(NBUF), .RING(LB_ROWS)) u_fb (
    .clk,
    .wr_en(fb_we), .wr_x(fb_wx), .wr_y(fb_wy), .wr_data(fb_wdata), .wr_buf(fb_wbuf),
    .rd_adv(adv), .rd_buf(gen_buf), .rd_x0(x0), .rd_y0(y0), .img_w(in_w), .img_h(in_h),
    .rd_win(win)
  );

  // Pipeline (every register advances with adv; valid/flags follow the data)
  //   A      window origin / phases            (banked_framebuf stage A)
  //   B      RAM data, coefficient lookup      (banked_framebuf stage B)
  //   W      window after the tap multiplexer
  //   M1     vertical products  pixel x CV     (one DSP48 each)
  //   T1..   vertical adder tree, one registered level per pairwise add
  //   S1     vertical result: (sum + 2^(F-1)) >>> F
  //   M2     horizontal products  vs x CH      (one DSP48 each)
  //   H1..   horizontal adder tree
  //   out    (sum + 2^(F-1)) >>> F, clamp -> m_axis
  // Every stage holds at most one multiply or one add, so the register-to-
  // register paths stay short for any TAPS. Products are exact and the sums
  // use the AW1 / AW2 accumulator widths, so results are bit-identical to
  // the single-cycle arithmetic (integer addition is associative).
  // Signed unpacked-array elements are wrapped in $signed() before casts:
  // sv2v otherwise emits an unsigned cast for them, which is numerically
  // identical but hides the operand width from the DSP mapper.
  logic [2:0]               f_q [NST];                   // {eof, eol, sof}
  logic [PHASE_BITS-1:0]    px_q, py_q;                  // phases (stage A)
  // horizontal coefficients travel with the data until stage M2
  localparam int CHD = 1 + 1 + LV + 1;                   // W, M1, T1..TLV, S1
  logic signed [COEF_W-1:0] ch_q [TAPS], cv_q [TAPS];    // B
  logic signed [COEF_W-1:0] cv_w [TAPS];                 // W
  logic signed [COEF_W-1:0] ch_d [CHD][TAPS];            // W .. S1
  logic [TAPS*TAPS*PIX_W-1:0] win_q;                     // W
  logic signed [AW1-1:0]    tv_q [LV+1][CHANNELS][TAPS][NP];  // [0] = M1 products
  logic signed [VW-1:0]     vs_q [CHANNELS][TAPS];            // S1
  logic signed [AW2-1:0]    th_q [LV+1][CHANNELS][NP];        // [0] = M2 products
  logic                     m_eof;

  // ---- M1 (comb): vertical products of every window pixel and component
  // (entries TAPS..NP-1 of the tree input are zero padding)
  logic signed [AW1-1:0] pv_c [CHANNELS][TAPS][NP];
  always_comb begin
    for (int c = 0; c < CHANNELS; c++)
      for (int k = 0; k < TAPS; k++)
        for (int j = 0; j < NP; j++)
          if (j < TAPS)
            pv_c[c][k][j] = AW1'(PV'($signed({1'b0, win_q[((j*TAPS)+k)*PIX_W + c*COMP_W +: COMP_W]}))
                                 * PV'($signed(cv_w[j])));
          else
            pv_c[c][k][j] = '0;
  end

  // ---- S1 (comb): round the tree result, keep it signed and unclamped
  logic signed [VW-1:0] vs_c [CHANNELS][TAPS];
  always_comb begin
    for (int c = 0; c < CHANNELS; c++)
      for (int k = 0; k < TAPS; k++)
        vs_c[c][k] = VW'(($signed(tv_q[LV][c][k][0]) + (AW1'(1) <<< (COEF_FRAC - 1))) >>> COEF_FRAC);
  end

  // ---- M2 (comb): horizontal products
  logic signed [AW2-1:0] ph_c [CHANNELS][NP];
  always_comb begin
    for (int c = 0; c < CHANNELS; c++)
      for (int k = 0; k < NP; k++)
        if (k < TAPS)
          ph_c[c][k] = AW2'(PH'($signed(vs_q[c][k])) * PH'($signed(ch_d[CHD-1][k])));
        else
          ph_c[c][k] = '0;
  end

  // ---- output (comb): round, clamp to [0, 2^COMP_W-1] (absorbs overshoot)
  localparam logic signed [AW2-1:0] MAXV = AW2'((1 << COMP_W) - 1);
  logic [PIX_W-1:0] out_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic signed [AW2-1:0] acc;
      acc = ($signed(th_q[LV][c][0]) + (AW2'(1) <<< (COEF_FRAC - 1))) >>> COEF_FRAC;
      if (acc < 0)         out_c[c*COMP_W +: COMP_W] = '0;
      else if (acc > MAXV) out_c[c*COMP_W +: COMP_W] = '1;
      else                 out_c[c*COMP_W +: COMP_W] = COMP_W'(acc);
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
      px_q  <= px;                              // A
      py_q  <= py;
      for (int t = 0; t < TAPS; t++) begin
        ch_q[t]    <= coef_h[px_q][t];          // B (with RAM data)
        cv_q[t]    <= coef_v[py_q][t];
        cv_w[t]    <= cv_q[t];                  // W
        ch_d[0][t] <= ch_q[t];
        for (int d = 1; d < CHD; d++) ch_d[d][t] <= ch_d[d-1][t];
      end
      win_q <= win;                             // W
      for (int c = 0; c < CHANNELS; c++) begin
        for (int k = 0; k < TAPS; k++) begin
          for (int j = 0; j < NP; j++) tv_q[0][c][k][j] <= pv_c[c][k][j];      // M1
          vs_q[c][k] <= vs_c[c][k];                                             // S1
        end
        for (int k = 0; k < NP; k++) th_q[0][c][k] <= ph_c[c][k];               // M2
      end
    end
  end

  // Adder trees: level l+1 node j = node 2j + node 2j+1 of level l.
  // Built with generate loops so every procedural loop has constant bounds.
  for (genvar l = 0; l < LV; l++) begin : g_tree
    for (genvar j = 0; j < (NP >> (l + 1)); j++) begin : g_node
      always_ff @(posedge clk) begin
        if (adv)
          for (int c = 0; c < CHANNELS; c++) begin
            for (int k = 0; k < TAPS; k++)                                      // T1..
              tv_q[l+1][c][k][j] <= $signed(tv_q[l][c][k][2*j]) + $signed(tv_q[l][c][k][2*j+1]);
            th_q[l+1][c][j] <= $signed(th_q[l][c][2*j]) + $signed(th_q[l][c][2*j+1]);   // H1..
          end
      end
    end
  end

  // Frame finished when the last output pixel is accepted by the sink
  // y of the pixel in read stage A (line-buffer flow control)
  always_ff @(posedge clk) if (adv) a_y <= d_y;

  assign gen_done = m_axis_tvalid && m_axis_tready && m_eof;

endmodule
