// ***************
// Filename: scaler_mip.sv
// Author: FPGA Cores 4 U
// Description: Mip-map scaler engine (trilinear/anisotropic).
//   Engine of scaler_trilinear (ANISO_MAX_LOG2 = 0) and
//   scaler_anisotropic (ANISO_MAX_LOG2 > 0). Frame flow:
//   1. capture the input frame as mip level 0
//   2. build LEVELS-1 levels with a 2x2 box filter
//        m[k+1](x,y) = (sum of the 2x2 block of m[k] + 2) >> 2
//      W[k+1] = max(1, W[k] >> 1), same for H (clamp-to-edge)
//   3. per output pixel take NP = 2^ANISO_LOG2 probes at
//        probe[n] = src + PROBE_START + n*PROBE_STEP          (16.16)
//      each a trilinear sample of levels L and L+1:
//        u_k = ((u + 0.5) >> k) - 0.5      level-k coordinate
//        t   = (bil_L*(256-f) + bil_L+1*f + 128) >> 8
//      output = (sum t + NP/2) >> ANISO_LOG2
//      L = LOD[15:8], f = LOD[7:0]; at the top level f is forced to 0.
//   IP registers:
//     0x040 LOD (8.8)             0x044 ANISO_LOG2 (clamped)
//     0x048/0x04C PROBE_STEP_X/Y  0x050/0x054 PROBE_START_X/Y (s16.16)
//     0x058 MIP_INFO (RO)         0x060+4k LEVEL_SIZE[k] (RO)
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 probe/clock = 1/NP output pixels/clock.
//   Latency: one input frame plus mip build (about W*H/3 cycles).
//   PINGPONG = 1 double-buffers level 0 and the pyramid, so the next frame
//   is captured while the current one is built and sampled.
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_mip #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int LEVELS        = 4,     // mip levels incl. level 0 (1..8)
  parameter int ANISO_MAX_LOG2 = 0,    // log2 of max probes (0..4)
  parameter int PHASE_BITS    = 8,     // bilinear phase resolution
  parameter logic [31:0] IP_ID = 32'h4D49_504D,               // "MIPM"
  parameter int PINGPONG      = 0,     // 1: double buffer (capture while generating)
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

  // CAPS = {PHASE_BITS, COMP_W, CHANNELS, LEVELS}
  localparam logic [31:0] CAPS = {8'(PHASE_BITS), 8'(COMP_W), 8'(CHANNELS), 8'(LEVELS)};
  localparam int          ONE  = 1 << PHASE_BITS;                 // weight 1.0
  localparam int          LW   = (LEVELS <= 1) ? 1 : $clog2(LEVELS); // level idx

  // Elaboration-time parameter checks
  initial begin
    if (LEVELS < 1 || LEVELS > 8)      $fatal(1, "scaler_mip: LEVELS must be 1..8");
    if (ANISO_MAX_LOG2 < 0 || ANISO_MAX_LOG2 > 4)
      $fatal(1, "scaler_mip: ANISO_MAX_LOG2 must be 0..4");
  end

  logic [31:0] ext_rdata;   // IP register read data (to scaler_ctrl)

  // ---------------------------------------------------------------- control
  // scaler_ctrl implements the AXI-Lite common registers, captures the
  // input frame into the frame buffer and sequences capture/generate.
  logic               fb_we;           // frame buffer write port
  logic [15:0]        fb_wx, fb_wy;
  logic [PIX_W-1:0]   fb_wdata;
  logic               fb_wbuf, gen_buf;     // ping-pong: capture / generate buffer
  logic               unused_lb_hold;       // line-buffer outputs, not used here
  logic signed [31:0] unused_nxt_y;
  logic               gen_start, gen_done;  // frame captured / frame sent
  logic [15:0]        in_w, in_h, out_w, out_h;   // IN_SIZE / OUT_SIZE
  logic [31:0]        step_x, step_y;  // STEP_X/Y   (u16.16)
  logic signed [31:0] offs_x, offs_y;  // OFFS_X/Y   (s16.16)
  logic               ext_wr, ext_rd;  // IP register bus (>= 0x040)
  logic [ADDR_W-1:0]  ext_waddr, ext_raddr;
  logic [31:0]        ext_wdata;

  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(IP_ID), .CAPS(CAPS), .NBUF(PINGPONG ? 2 : 1)) u_ctrl (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
    .fb_we, .fb_wx, .fb_wy, .fb_wdata,
    .fb_wbuf, .gen_buf, .gen_start, .gen_done,
    // no line-buffer mode: the mip pyramid needs the whole frame
    .lb_nxt_y(32'sd0), .lb_nxt_v(1'b0), .lb_o_y(32'sd0), .lb_o_v(1'b0),
    .lb_a_y(32'sd0), .lb_a_v(1'b0), .lb_hold(unused_lb_hold),
    .cfg_in_w(in_w), .cfg_in_h(in_h), .cfg_out_w(out_w), .cfg_out_h(out_h),
    .cfg_step_x(step_x), .cfg_step_y(step_y), .cfg_offs_x(offs_x), .cfg_offs_y(offs_y),
    .ext_wr, .ext_waddr, .ext_wdata, .ext_rd, .ext_raddr, .ext_rdata(ext_rdata)
  );

  // ---------------------------------------------------------------- IP registers
  logic [15:0]        lod;               // LOD, unsigned 8.8
  logic [3:0]         aniso_log2_r;      // log2(probes per pixel)
  logic signed [31:0] pstep_x, pstep_y, pstart_x, pstart_y;  // s16.16
  logic [15:0]        lw [LEVELS], lh [LEVELS];   // size of each level

  // Level sizes: each level halves the previous one (never below 1)
  always_comb begin
    lw[0] = in_w;
    lh[0] = in_h;
    for (int k = 1; k < LEVELS; k++) begin
      lw[k] = (lw[k-1] > 16'd1) ? (lw[k-1] >> 1) : 16'd1;
      lh[k] = (lh[k-1] > 16'd1) ? (lh[k-1] >> 1) : 16'd1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lod          <= '0;
      aniso_log2_r <= '0;
      pstep_x      <= '0;
      pstep_y      <= '0;
      pstart_x     <= '0;
      pstart_y     <= '0;
      ext_rdata    <= '0;
    end else begin
      // IP register writes (ANISO_LOG2 is clamped to the build maximum)
      if (ext_wr) begin
        case (ext_waddr[7:0])
          8'h40: lod          <= ext_wdata[15:0];
          8'h44: aniso_log2_r <= (ext_wdata[3:0] > 4'(ANISO_MAX_LOG2)) ?
                                 4'(ANISO_MAX_LOG2) : ext_wdata[3:0];
          8'h48: pstep_x      <= ext_wdata;
          8'h4C: pstep_y      <= ext_wdata;
          8'h50: pstart_x     <= ext_wdata;
          8'h54: pstart_y     <= ext_wdata;
          default: ;
        endcase
      end
      // IP register reads (registered, 1-cycle latency)
      if (ext_rd) begin
        ext_rdata <= '0;
        case (ext_raddr[7:0])
          8'h40: ext_rdata <= {16'd0, lod};
          8'h44: ext_rdata <= {28'd0, aniso_log2_r};
          8'h48: ext_rdata <= pstep_x;
          8'h4C: ext_rdata <= pstep_y;
          8'h50: ext_rdata <= pstart_x;
          8'h54: ext_rdata <= pstart_y;
          8'h58: ext_rdata <= {8'd0, 8'(PHASE_BITS), 8'(ANISO_MAX_LOG2), 8'(LEVELS)};
          default: begin               // 0x060 + 4k : LEVEL_SIZE[k]
            for (int k = 0; k < LEVELS; k++)
              if (ext_raddr[7:0] == 8'(8'h60 + 4 * k)) ext_rdata <= {lh[k], lw[k]};
          end
        endcase
      end
    end
  end

  // Level selection from the LOD register (static for a frame):
  // lvl_a = floor(LOD), lvl_b = lvl_a + 1, lod_f = blend weight of lvl_b.
  // At or beyond the top level both are the top level and lod_f = 0.
  logic [LW-1:0] lvl_a, lvl_b;
  logic [7:0]    lod_f;
  always_comb begin
    if (lod[15:8] >= 8'(LEVELS - 1)) begin
      lvl_a = LW'(LEVELS - 1);
      lvl_b = LW'(LEVELS - 1);
      lod_f = 8'd0;
    end else begin
      lvl_a = LW'(lod[15:8]);
      lvl_b = LW'(lod[15:8] + 8'd1);
      lod_f = lod[7:0];
    end
  end

  // ---------------------------------------------------------------- sequencing
  // Generation phase states (after scaler_ctrl signals gen_start):
  //   G_IDLE   : waiting for a captured frame
  //   G_MIP    : reading level mip_src and writing level mip_src+1
  //   G_DRAIN  : waiting for the last mip write of the level to land
  //   G_SAMPLE : producing the output frame from the pyramid
  typedef enum logic [1:0] {G_IDLE, G_MIP, G_DRAIN, G_SAMPLE} gstate_t;
  gstate_t gstate;

  // Global pipeline advance: every stage moves forward unless the output
  // register holds a beat the sink has not accepted yet.
  wire adv = !m_axis_tvalid || m_axis_tready;

  // mip generation state
  logic [LW-1:0]      mip_src;            // level being read
  logic [15:0]        mx, my;             // destination pixel being issued
  logic [1:0]         mv;                 // read pipeline valid
  logic [15:0]        mpx [2], mpy [2];   // destination x/y in the pipe
  logic               mw_en;              // mip write strobe
  logic [LW-1:0]      mw_lvl;             // level being written
  logic [15:0]        mw_x, mw_y;         // mip write position
  logic [PIX_W-1:0]   mw_data;            // 2x2 box average
  logic               dda_start;          // start output generation

  // destination level, its size, and end-of-level detection
  wire [LW:0] mip_dst = mip_src + 1'b1;
  wire [15:0] dst_w   = lw[mip_dst[LW-1:0]];
  wire [15:0] dst_h   = lh[mip_dst[LW-1:0]];
  wire        mip_issue = (gstate == G_MIP);
  wire        mip_last  = (mx == dst_w - 16'd1) && (my == dst_h - 16'd1);

  // ---------------------------------------------------------------- frame buffers
  // One 2x2-window banked frame buffer per level. Level 0 is written by
  // the capture logic, the others by the mip generator. During mip
  // build the read port of every level addresses (2*mx, 2*my); during
  // sampling level lvl_a gets the A coordinates and all others the B
  // coordinates (only lvl_b's window is used).
  logic [4*PIX_W-1:0] win [LEVELS];                     // 2x2 per level
  logic signed [17:0] ra_x, ra_y, rb_x, rb_y;           // sampling window origins
  logic [PHASE_BITS-1:0] fa_x, fa_y, fb_x, fb_y;        // sampling phases

  for (genvar k = 0; k < LEVELS; k++) begin : g_lvl
    logic               we;
    logic [15:0]        wx, wy;
    logic [PIX_W-1:0]   wd;
    logic               wb;                 // buffer written (ping-pong)
    logic signed [17:0] rx, ry;
    logic               radv;
    always_comb begin
      // level 0 is written by the capture (fb_wbuf); the mip levels are
      // built inside the buffer being generated (gen_buf)
      if (k == 0) begin
        we = fb_we; wx = fb_wx; wy = fb_wy; wd = fb_wdata; wb = fb_wbuf;
      end else begin
        we = mw_en && (mw_lvl == LW'(k)); wx = mw_x; wy = mw_y; wd = mw_data; wb = gen_buf;
      end
      if (gstate != G_SAMPLE) begin
        rx   = 18'(mx) <<< 1;
        ry   = 18'(my) <<< 1;
        radv = 1'b1;
      end else begin
        rx   = (LW'(k) == lvl_a) ? ra_x : rb_x;
        ry   = (LW'(k) == lvl_a) ? ra_y : rb_y;
        radv = adv;
      end
    end
    banked_framebuf #(.PIX_W(PIX_W), .TAPS(2),
                      .MAX_W((MAX_W >> k) > 0 ? (MAX_W >> k) : 1),
                      .MAX_H((MAX_H >> k) > 0 ? (MAX_H >> k) : 1),
                      .NBUF(PINGPONG ? 2 : 1)) u_fb (
      .clk,
      .wr_en(we), .wr_x(wx), .wr_y(wy), .wr_data(wd), .wr_buf(wb),
      .rd_adv(radv), .rd_buf(gen_buf), .rd_x0(rx), .rd_y0(ry), .img_w(lw[k]), .img_h(lh[k]),
      .rd_win(win[k])
    );
  end

  // 2x2 box average of the source-level window, rounded: (sum + 2) >> 2
  logic [PIX_W-1:0] box;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [COMP_W+1:0] s;
      s = (COMP_W+2)'(win[mip_src][(0*PIX_W) + c*COMP_W +: COMP_W])
        + (COMP_W+2)'(win[mip_src][(1*PIX_W) + c*COMP_W +: COMP_W])
        + (COMP_W+2)'(win[mip_src][(2*PIX_W) + c*COMP_W +: COMP_W])
        + (COMP_W+2)'(win[mip_src][(3*PIX_W) + c*COMP_W +: COMP_W]) + 2;
      box[c*COMP_W +: COMP_W] = COMP_W'(s >> 2);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gstate    <= G_IDLE;
      mip_src   <= '0;
      mx        <= '0;
      my        <= '0;
      mv        <= '0;
      mw_en     <= 1'b0;
      mw_lvl    <= '0;
      mw_x      <= '0;
      mw_y      <= '0;
      mw_data   <= '0;
      dda_start <= 1'b0;
      for (int i = 0; i < 2; i++) begin mpx[i] <= '0; mpy[i] <= '0; end
    end else begin
      dda_start <= 1'b0;
      mw_en     <= 1'b0;
      // read pipeline bookkeeping (mip build): destination coordinates
      // travel with the 2-cycle frame buffer read, then the box average
      // is written to the destination level
      mv[0]  <= mip_issue;
      mpx[0] <= mx;  mpy[0] <= my;
      mv[1]  <= mv[0];
      mpx[1] <= mpx[0]; mpy[1] <= mpy[0];
      if (mv[1]) begin
        mw_en   <= 1'b1;
        mw_lvl  <= mip_dst[LW-1:0];
        mw_x    <= mpx[1];
        mw_y    <= mpy[1];
        mw_data <= box;
      end
      case (gstate)
        // frame captured: build the pyramid (or sample directly)
        G_IDLE: if (gen_start) begin
          mip_src <= '0;
          mx <= '0; my <= '0;
          if (LEVELS > 1) gstate <= G_MIP;
          else begin gstate <= G_SAMPLE; dda_start <= 1'b1; end
        end
        // issue one destination pixel per clock in raster order
        G_MIP: begin
          if (mip_last) gstate <= G_DRAIN;
          else if (mx == dst_w - 16'd1) begin mx <= '0; my <= my + 16'd1; end
          else mx <= mx + 16'd1;
        end
        // level complete: next level, or start the output frame
        G_DRAIN: if (mv == 2'b00 && !mv[1] && !mw_en) begin
          mx <= '0; my <= '0;
          if (32'(mip_dst) < LEVELS - 1) begin
            mip_src <= mip_dst[LW-1:0];
            gstate  <= G_MIP;
          end else begin
            gstate    <= G_SAMPLE;
            dda_start <= 1'b1;
          end
        end
        // output frame running until its last pixel is accepted
        G_SAMPLE: if (gen_done) gstate <= G_IDLE;
        default: gstate <= G_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- DDA + probes
  // The DDA gives the source position of each output pixel. The probe
  // stage expands it into NP = 2^ANISO_LOG2 probe positions
  // src + PROBE_START + n*PROBE_STEP; the DDA only advances after the
  // last probe of a pixel has been issued.
  logic               d_valid, d_sof, d_eol, d_eof, d_busy;
  logic signed [31:0] d_x, d_y;
  logic [3:0]         pn;                 // probe index
  logic signed [31:0] off_x, off_y;
  wire  [3:0]         np_last = 4'((1 << aniso_log2_r) - 1);   // NP-1
  wire                probe_last = (pn == np_last);
  wire                dda_adv = adv && (gstate == G_SAMPLE) && (!d_valid || probe_last);

  scaler_dda u_dda (
    .clk, .rst_n, .start(dda_start), .adv(dda_adv), .hold(1'b0), .nxt_y(unused_nxt_y),
    .out_w, .out_h, .step_x, .step_y, .offs_x, .offs_y,
    .busy(d_busy), .o_valid(d_valid), .o_x(d_x), .o_y(d_y),
    .o_sof(d_sof), .o_eol(d_eol), .o_eof(d_eof)
  );

  // probe stage registers (stage P)
  logic               p_valid, p_first, p_last;
  logic [2:0]         p_flags;            // {eof, eol, sof}
  logic signed [31:0] p_x, p_y;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_valid <= 1'b0; p_first <= 1'b0; p_last <= 1'b0; p_flags <= '0;
      p_x <= '0; p_y <= '0; pn <= '0; off_x <= '0; off_y <= '0;
    end else if (dda_start) begin
      p_valid <= 1'b0;
      pn      <= '0;
      off_x   <= pstart_x;
      off_y   <= pstart_y;
    end else if (adv) begin
      p_valid <= d_valid && (gstate == G_SAMPLE);
      if (d_valid && gstate == G_SAMPLE) begin
        p_x     <= d_x + off_x;
        p_y     <= d_y + off_y;
        p_first <= (pn == 4'd0);
        p_last  <= probe_last;
        p_flags <= {d_eof, d_eol, d_sof};
        // next probe offset, or rewind for the next pixel
        if (probe_last) begin
          pn <= '0; off_x <= pstart_x; off_y <= pstart_y;
        end else begin
          pn <= pn + 4'd1; off_x <= off_x + pstep_x; off_y <= off_y + pstep_y;
        end
      end
    end
  end

  // ---------------------------------------------------------------- level coordinates
  // Map the probe position to levels lvl_a / lvl_b: u_k = ((u+0.5) >> k)
  // - 0.5, then round to the PHASE_BITS grid to get window origin and
  // bilinear phase (same scheme as scaler_bilinear).
  localparam logic signed [31:0] RND = 32'sd1 <<< (16 - PHASE_BITS - 1);
  logic signed [31:0] ua_x, ua_y, ub_x, ub_y;
  always_comb begin
    ua_x = ((p_x + 32'sh8000) >>> lvl_a) - 32'sh8000 + RND;
    ua_y = ((p_y + 32'sh8000) >>> lvl_a) - 32'sh8000 + RND;
    ub_x = ((p_x + 32'sh8000) >>> lvl_b) - 32'sh8000 + RND;
    ub_y = ((p_y + 32'sh8000) >>> lvl_b) - 32'sh8000 + RND;
    ra_x = 18'(ua_x >>> 16);  fa_x = ua_x[15 -: PHASE_BITS];
    ra_y = 18'(ua_y >>> 16);  fa_y = ua_y[15 -: PHASE_BITS];
    rb_x = 18'(ub_x >>> 16);  fb_x = ub_x[15 -: PHASE_BITS];
    rb_y = 18'(ub_y >>> 16);  fb_y = ub_y[15 -: PHASE_BITS];
  end

  // ---------------------------------------------------------------- sampling pipeline
  // Pipeline (every register advances with adv; valid/flags follow the data)
  //   A    window origins / phases of both levels  (banked_framebuf stage A)
  //   B    RAM data                                (banked_framebuf stage B)
  //   W    level windows after the tap and level multiplexers
  //   M1   p * (ONE - fx), p * fx          both levels     (DSP48)
  //   S1   top / bot row sums
  //   M2   top * (ONE - fy), bot * fy      both levels     (DSP48)
  //   S2   bilinear samples sa, sb = (sum + ONE^2/2) >> 2*PHASE_BITS
  //   M3   blend products sa * (256 - f), sb * f
  //   out  t = (sum + 128) >> 8, accumulated over the probes of a pixel;
  //        on the last probe the rounded mean is sent to m_axis
  // One multiply or one add per stage (plus the probe accumulator);
  // bit-identical to the single-cycle form.
  localparam int NST = 8;
  localparam int HW  = COMP_W + PHASE_BITS + 1;
  localparam int VW  = HW + PHASE_BITS + 1;
  localparam int BW3 = COMP_W + 9;                  // blend product width
  logic [NST-1:0]        v_q;
  logic [4:0]            f_q [NST];         // {first, last, eof, eol, sof}
  logic [PHASE_BITS-1:0] fr_q [2][4];       // {ax, ay, bx, by}: A, B
  logic [PHASE_BITS:0]   wx_q [2][2];       // W: level a/b: {ONE-fx, fx}
  logic [PHASE_BITS:0]   wy_d [3][2][2];    // W, M1, S1: level a/b: {ONE-fy, fy}
  logic [4*PIX_W-1:0]    wa_q, wb_q;        // W
  logic [HW-1:0]         p1_q [2][CHANNELS][4];   // M1 [level][c][tap]
  logic [HW-1:0]         r1_q [2][CHANNELS][2];   // S1 top, bot
  logic [VW-1:0]         p2_q [2][CHANNELS][2];   // M2
  logic [COMP_W-1:0]     sab_q [2][CHANNELS];     // S2: sa, sb
  logic [BW3-1:0]        p3_q [2][CHANNELS];      // M3
  logic                  m_eof;

  // ---- out (comb): trilinear blend, probe accumulation and mean
  localparam int ACW = COMP_W + 5;
  logic [ACW-1:0]   acc_q [CHANNELS];
  logic [ACW-1:0]   acc_c [CHANNELS];
  logic [PIX_W-1:0] avg_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      logic [BW3-1:0] t;
      t = p3_q[0][c] + p3_q[1][c] + BW3'(128);
      acc_c[c] = (f_q[NST-1][4] ? '0 : acc_q[c]) + ACW'(t >> 8);
      avg_c[c*COMP_W +: COMP_W] =
        COMP_W'((acc_c[c] + ACW'((1 << aniso_log2_r) >> 1)) >> aniso_log2_r);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q <= '0;
      for (int k = 0; k < NST; k++) f_q[k] <= '0;
      for (int c = 0; c < CHANNELS; c++) acc_q[c] <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= '0;
      m_axis_tuser  <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_eof         <= 1'b0;
    end else if (dda_start) begin
      v_q <= '0;                          // flush at the start of a frame
    end else if (adv) begin
      v_q[0] <= p_valid;
      f_q[0] <= {p_first, p_last, p_flags};
      for (int k = 1; k < NST; k++) begin
        v_q[k] <= v_q[k-1];
        f_q[k] <= f_q[k-1];
      end
      if (v_q[NST-1])
        for (int c = 0; c < CHANNELS; c++) acc_q[c] <= acc_c[c];
      // only the last probe of a pixel produces an output beat
      m_axis_tvalid <= v_q[NST-1] && f_q[NST-1][3];
      m_axis_tdata  <= avg_c;
      {m_eof, m_axis_tlast, m_axis_tuser} <= f_q[NST-1][2:0];
    end
  end

  // Data path registers (no reset needed)
  always_ff @(posedge clk) begin
    logic [4*PIX_W-1:0] ws;                                        // level window
    if (adv) begin
      fr_q[0][0] <= fa_x;                                          // A
      fr_q[0][1] <= fa_y;
      fr_q[0][2] <= fb_x;
      fr_q[0][3] <= fb_y;
      for (int i = 0; i < 4; i++) fr_q[1][i] <= fr_q[0][i];       // B
      wa_q <= win[lvl_a];                                          // W
      wb_q <= win[lvl_b];
      for (int l = 0; l < 2; l++) begin
        wx_q[l][0]    <= (PHASE_BITS+1)'(ONE) - (PHASE_BITS+1)'(fr_q[1][2*l]);
        wx_q[l][1]    <= (PHASE_BITS+1)'(fr_q[1][2*l]);
        wy_d[0][l][0] <= (PHASE_BITS+1)'(ONE) - (PHASE_BITS+1)'(fr_q[1][2*l+1]);
        wy_d[0][l][1] <= (PHASE_BITS+1)'(fr_q[1][2*l+1]);
        for (int d = 1; d < 3; d++) begin
          wy_d[d][l][0] <= wy_d[d-1][l][0];
          wy_d[d][l][1] <= wy_d[d-1][l][1];
        end
      end
      for (int c = 0; c < CHANNELS; c++)
        for (int l = 0; l < 2; l++) begin
          ws = (l == 0) ? wa_q : wb_q;                             // M1
          for (int t = 0; t < 4; t++)
            p1_q[l][c][t] <= HW'(ws[(t*PIX_W) + c*COMP_W +: COMP_W]) * HW'(wx_q[l][t % 2]);
          r1_q[l][c][0] <= p1_q[l][c][0] + p1_q[l][c][1];          // S1
          r1_q[l][c][1] <= p1_q[l][c][2] + p1_q[l][c][3];
          p2_q[l][c][0] <= VW'(r1_q[l][c][0]) * VW'(wy_d[2][l][0]);  // M2
          p2_q[l][c][1] <= VW'(r1_q[l][c][1]) * VW'(wy_d[2][l][1]);
          sab_q[l][c]   <= COMP_W'((p2_q[l][c][0] + p2_q[l][c][1]  // S2
                                    + VW'(ONE * ONE / 2)) >> (2 * PHASE_BITS));
          p3_q[l][c]    <= BW3'(sab_q[l][c])                       // M3
                         * ((l == 0) ? BW3'(9'd256 - lod_f) : BW3'(lod_f));
        end
    end
  end

  // Frame finished when the last output pixel is accepted by the sink
  assign gen_done = m_axis_tvalid && m_axis_tready && m_eof;

endmodule
