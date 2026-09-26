// ***************
// Filename: axis_out_ctrl.sv
// Author: Paul Barcelona
// Description: Generates the output raster and AXI4-Stream video
// master. Drives coord_gen for each pixel's source address,
// expands it for bilinear or bicubic sampling, muxes between
// the fast (radial) and slow (per-pixel-divide) coord_gen
// paths, and paces requests when either bicubic or a slow
// model is active.
// Date: September 26, 2026
// ***************
// =============================================================================
// axis_out_ctrl.sv
//
// Generates the output raster, drives coord_gen to compute the fractional
// source address for each output pixel, expands that into the frame_buffer
// read address(es) (with clamp-to-edge boundary handling), and produces
// the interpolated AXI4-Stream video output. Two interpolation modes,
// selected per-frame by `interp_mode` (must be held stable for the
// duration of a frame -- changing it mid-frame is not supported):
//
//   BILINEAR (interp_mode=0, default): the original, fully-pipelined,
//   never-stalling 2x2-tap datapath. One output pixel per clock, with a
//   fixed TOTAL_LATENCY_BILINEAR=13-cycle delay -- this reproduces the
//   exact same "line, then LINE_GAP_CYCLES idle" timing at the output as
//   at the input, because every stage always flows.
//
//   BICUBIC (interp_mode=1): a 4x4-tap separable Catmull-Rom filter
//   (bicubic.sv). The on-chip frame_buffer has only four read ports
//   (sized for bilinear's 2x2 footprint -- see frame_buffer.sv), so a
//   4x4 footprint is gathered as four SEQUENTIAL row-reads over the same
//   four ports rather than by replicating the memory sixteen-fold. This
//   is a deliberate area/throughput trade-off: bicubic mode does NOT
//   sustain 1 pixel/clock and does NOT reproduce the input's line timing
//   at the output -- it processes one pixel at a time (a new source
//   request is only issued once the previous one has fully completed),
//   taking TOTAL_LATENCY_BICUBIC=19 cycles per pixel end-to-end. This is
//   an honest trade-off for a reference design reusing an existing
//   bilinear-sized memory system; a production design targeting bicubic
//   at full rate would size the frame buffer with 16 read ports (or use
//   an external-memory tile cache) instead. See README for the full
//   derivation of both latency numbers.
//
// coord_gen itself is COMPLETELY UNCHANGED between the two modes -- both
// need the same fractional source coordinate (sx,sy); only how far the
// tap footprint is expanded, and how many memory read cycles it costs,
// differs downstream.
//
// This design assumes the downstream consumer is always ready
// (m_axis_tready held high) -- consistent with a fixed-rate video
// pipeline; there is no mid-pipeline stall capability (documented
// trade-off, see README).
// =============================================================================
import vision_system_pkg::*;
import distortion_model_pkg::*;

module axis_out_ctrl #(
  parameter int COORD_W = COORD_W,
  parameter int ADDR_W  = ADDR_W
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // control
  input  logic                 start_output,     // 1-cycle pulse: begin generating a frame
  input  logic [COORD_W-1:0]   img_width,
  input  logic [COORD_W-1:0]   img_height,
  input  logic                 interp_mode,      // 0=bilinear, 1=bicubic; static per frame
  output logic                 busy,
  output logic                 frame_out_done,   // 1-cycle pulse: last output beat sent

  // configuration (passed straight through to coord_gen as a single
  // struct -- see distortion_model_pkg.sv)
  input  calib_params_t        cfg,

  // frame_buffer read port
  output logic                 fb_rd_en,
  output logic [ADDR_W-1:0]    fb_rd_addr0,
  output logic [ADDR_W-1:0]    fb_rd_addr1,
  output logic [ADDR_W-1:0]    fb_rd_addr2,
  output logic [ADDR_W-1:0]    fb_rd_addr3,
  input  logic [PIX_W-1:0]     fb_rd_data0,
  input  logic [PIX_W-1:0]     fb_rd_data1,
  input  logic [PIX_W-1:0]     fb_rd_data2,
  input  logic [PIX_W-1:0]     fb_rd_data3,

  // AXI4-Stream master (video out)
  output logic                 m_axis_tvalid,
  input  logic                 m_axis_tready,
  output logic [PIX_W-1:0]     m_axis_tdata,
  output logic                 m_axis_tlast,
  output logic                 m_axis_tuser
);

  // ---------------------------------------------------------------------
  // Raster / gap generator (request side)
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_ACTIVE, R_GAP, R_DONE} rstate_t;
  rstate_t rstate;

  logic [COORD_W-1:0] x_cnt, y_cnt;
  logic [2:0]          gap_cnt;
  logic                 req_valid, req_tlast, req_tuser;
  logic [COORD_W-1:0]   req_x, req_y;

  // Bicubic mode has no per-cycle throughput -- only one source request
  // may be outstanding (in flight through coord_gen + the bicubic gather
  // FSM) at a time. Neither does coord_gen's own "slow path" for
  // MODEL_FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE (a per-pixel
  // reciprocal divide -- see coord_gen.sv). req_outstanding is set when
  // a request is issued under either condition and cleared once the
  // LAST stage that's actually slow finishes: bc_valid if bicubic mode
  // is active (regardless of whether coord_gen itself is also slow --
  // bc_valid only ever fires after coord_gen has already produced its
  // result, so it's still the correct final-completion signal), else
  // cg_valid directly if only coord_gen itself is slow (bilinear
  // downstream is fast/always-flowing, so coord_gen's own result is the
  // bottleneck). The raster generator simply holds at the current pixel
  // (no req_valid, no advance) while req_outstanding is set. When
  // neither condition applies (bilinear + MODEL_RADIAL/MODEL_AFFINE/
  // MODEL_SCALING) this is unused (the original fully-pipelined,
  // always-advancing design).
  logic req_outstanding;
  logic bc_valid;             // forward-declared; driven by the gather FSM below
  logic cg_busy;              // forward-declared; driven by coord_gen below
  logic model_is_slow_div;
  logic               cg_valid;
  logic signed [31:0] cg_sx, cg_sy;
  assign model_is_slow_div = (cfg.model_sel == MODEL_FISHEYE) ||
                              (cfg.model_sel == MODEL_PANORAMIC) ||
                              (cfg.model_sel == MODEL_PERSPECTIVE);
  logic need_pacing;
  assign need_pacing = interp_mode || model_is_slow_div;
  logic raster_can_issue;
  assign raster_can_issue = need_pacing ? !req_outstanding : 1'b1;
  logic req_done_pulse;
  assign req_done_pulse = interp_mode ? bc_valid : (model_is_slow_div && cg_valid);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; x_cnt <= '0; y_cnt <= '0; gap_cnt <= '0;
      req_valid <= 1'b0; req_tlast <= 1'b0; req_tuser <= 1'b0;
      req_x <= '0; req_y <= '0; req_outstanding <= 1'b0;
    end else begin
      req_valid <= 1'b0; req_tlast <= 1'b0; req_tuser <= 1'b0;
      if (req_done_pulse) req_outstanding <= 1'b0;
      unique case (rstate)
        R_IDLE: begin
          if (start_output && img_width != 0 && img_height != 0) begin
            x_cnt <= '0; y_cnt <= '0;
            rstate <= R_ACTIVE;
          end
        end
        R_ACTIVE: begin
          if (raster_can_issue) begin
            req_valid <= 1'b1;
            req_x     <= x_cnt;
            req_y     <= y_cnt;
            req_tlast <= (x_cnt == img_width - 1);
            req_tuser <= (x_cnt == 0) && (y_cnt == 0);
            if (need_pacing) req_outstanding <= 1'b1;
            if (x_cnt == img_width - 1) begin
              if (y_cnt == img_height - 1) begin
                rstate <= R_DONE;
              end else begin
                x_cnt   <= '0;
                y_cnt   <= y_cnt + 1'b1;
                gap_cnt <= '0;
                rstate  <= R_GAP;
              end
            end else begin
              x_cnt <= x_cnt + 1'b1;
            end
          end
          // else: not yet safe to issue the next request -- hold at the
          // current x_cnt,y_cnt and re-check next cycle.
        end
        R_GAP: begin
          if (gap_cnt == LINE_GAP_CYCLES - 1) rstate <= R_ACTIVE;
          else                                gap_cnt <= gap_cnt + 1'b1;
        end
        R_DONE: begin
          rstate <= R_IDLE;
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  assign busy = (rstate != R_IDLE);

  // ---------------------------------------------------------------------
  // coord_gen: request (x,y) -> fractional source address. 9-cycle fixed
  // latency for MODEL_RADIAL/MODEL_AFFINE/MODEL_SCALING; for MODEL_
  // FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE, a much longer, also-fixed
  // latency (measured, not assumed -- see README) via coord_gen's own
  // internal per-pixel-divide "slow path", signaled by cg_busy.
  // ---------------------------------------------------------------------

  coord_gen #(.COORD_W(COORD_W)) u_coord_gen (
    .clk, .rst_n,
    .cfg,
    .in_valid (req_valid),
    .in_x     (req_x),
    .in_y     (req_y),
    .out_valid (cg_valid),
    .out_sx_q16(cg_sx),
    .out_sy_q16(cg_sy),
    .busy      (cg_busy)
  );

  // ---------------------------------------------------------------------
  // Address-expand stage: split into integer/fraction, clamp-to-edge,
  // compute the two row base addresses (single multiply: y0*width) and
  // the four corner read addresses. +1 cycle latency.
  // ---------------------------------------------------------------------
  logic                ae_valid;
  logic [7:0]           ae_fx, ae_fy;
  logic [ADDR_W-1:0]    ae_addr_tl, ae_addr_tr, ae_addr_bl, ae_addr_br;

  logic signed [COORD_W+1:0] x0_s, y0_s;      // extra headroom for clamp compares
  logic [7:0]                fx_c, fy_c;
  logic [COORD_W-1:0]        x0_clamped, y0_clamped;
  logic [ADDR_W-1:0]         rowbase0, rowbase1;

  always_comb begin
    x0_s = cg_sx >>> FRAC_BITS;
    y0_s = cg_sy >>> FRAC_BITS;

    if (cg_sx < 0) begin
      x0_clamped = '0;
      fx_c       = 8'd0;                 // fully weight the leftmost column
    end else if (x0_s > $signed({2'b00, img_width}) - 2) begin
      x0_clamped = img_width - 2;
      fx_c       = 8'd255;               // fully weight the rightmost column
    end else begin
      x0_clamped = x0_s[COORD_W-1:0];
      fx_c       = cg_sx[15:8];
    end

    if (cg_sy < 0) begin
      y0_clamped = '0;
      fy_c       = 8'd0;                 // fully weight the topmost row
    end else if (y0_s > $signed({2'b00, img_height}) - 2) begin
      y0_clamped = img_height - 2;
      fy_c       = 8'd255;               // fully weight the bottommost row
    end else begin
      y0_clamped = y0_s[COORD_W-1:0];
      fy_c       = cg_sy[15:8];
    end

    rowbase0 = y0_clamped * img_width;
    rowbase1 = rowbase0 + img_width;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ae_valid <= 1'b0; ae_fx <= '0; ae_fy <= '0;
      ae_addr_tl <= '0; ae_addr_tr <= '0; ae_addr_bl <= '0; ae_addr_br <= '0;
    end else begin
      ae_valid   <= cg_valid;
      ae_fx      <= fx_c;
      ae_fy      <= fy_c;
      ae_addr_tl <= rowbase0 + x0_clamped;
      ae_addr_tr <= rowbase0 + x0_clamped + 1'b1;
      ae_addr_bl <= rowbase1 + x0_clamped;
      ae_addr_br <= rowbase1 + x0_clamped + 1'b1;
    end
  end

  // These become the BILINEAR-path candidate for the frame_buffer read
  // port; muxed against the bicubic gather FSM's requests below.
  logic              bl_rd_en;
  logic [ADDR_W-1:0] bl_rd_addr0, bl_rd_addr1, bl_rd_addr2, bl_rd_addr3;
  assign bl_rd_en    = ae_valid;
  assign bl_rd_addr0 = ae_addr_tl;
  assign bl_rd_addr1 = ae_addr_tr;
  assign bl_rd_addr2 = ae_addr_bl;
  assign bl_rd_addr3 = ae_addr_br;

  // frame_buffer read itself is synchronous (+1 cycle); delay fx,fy and
  // valid to stay aligned with fb_rd_data*.
  logic        rd_valid;
  logic [7:0]  rd_fx, rd_fy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid <= 1'b0; rd_fx <= '0; rd_fy <= '0;
    end else begin
      rd_valid <= ae_valid;
      rd_fx    <= ae_fx;
      rd_fy    <= ae_fy;
    end
  end

  // ---------------------------------------------------------------------
  // Bilinear interpolation, 2-cycle latency
  // ---------------------------------------------------------------------
  logic               bl_valid;
  logic [PIX_W-1:0]   bl_pixel;

  bilinear u_bilinear (
    .clk, .rst_n,
    .valid_in (rd_valid),
    .fx (rd_fx), .fy (rd_fy),
    .tl (fb_rd_data0), .tr (fb_rd_data1), .bl (fb_rd_data2), .br (fb_rd_data3),
    .valid_out (bl_valid),
    .pixel_out (bl_pixel)
  );

  // =======================================================================
  // BICUBIC gather FSM: given coord_gen's (cg_sx,cg_sy), sequentially
  // gathers the 4x4=16-tap footprint over four cycles (reusing the same
  // four frame_buffer read ports bilinear uses -- one row of 4 taps per
  // cycle), then hands the taps + fractional weights to bicubic.sv.
  // Anchor x0 (=floor(sx)) is clamped into [1, W-3] (and y0 into
  // [1, H-3]) so that x0-1 and x0+2 are always in-bounds without any
  // per-tap clamping -- this requires img_width>=4 and img_height>=4 in
  // bicubic mode (documented minimum; not a concern for any realistic
  // frame size). As with bilinear's edge fix, the fractional weight is
  // forced to 0 (full weight on the anchor tap) whenever the anchor
  // itself had to be clamped, rather than left derived from an
  // out-of-range coordinate.
  // =======================================================================
  logic signed [COORD_W+1:0] bcx0_s, bcy0_s;
  logic [COORD_W-1:0]        bcx0_c, bcy0_c;
  logic [31:0]                bctx_c, bcty_c;

  always_comb begin
    bcx0_s = cg_sx >>> FRAC_BITS;
    bcy0_s = cg_sy >>> FRAC_BITS;

    if (cg_sx < 0 || bcx0_s < 1) begin
      bcx0_c = (img_width >= 4) ? 1 : 1;
      bctx_c = 32'd0;
    end else if (bcx0_s > $signed({2'b00, img_width}) - 3) begin
      bcx0_c = (img_width >= 4) ? (img_width - 3) : 1;
      bctx_c = 32'd0;
    end else begin
      bcx0_c = bcx0_s[COORD_W-1:0];
      bctx_c = {16'h0, cg_sx[15:0]};
    end

    if (cg_sy < 0 || bcy0_s < 1) begin
      bcy0_c = (img_height >= 4) ? 1 : 1;
      bcty_c = 32'd0;
    end else if (bcy0_s > $signed({2'b00, img_height}) - 3) begin
      bcy0_c = (img_height >= 4) ? (img_height - 3) : 1;
      bcty_c = 32'd0;
    end else begin
      bcy0_c = bcy0_s[COORD_W-1:0];
      bcty_c = {16'h0, cg_sy[15:0]};
    end
  end

  typedef enum logic [2:0] {BC_IDLE, BC_R1, BC_R2, BC_R3, BC_R4} bcstate_t;
  bcstate_t bcstate;

  logic [COORD_W-1:0] bcx0_lock, bcy0_lock;
  logic [31:0]         bctx_lock, bcty_lock;
  logic [PIX_W-1:0]    p0_0,p0_1,p0_2,p0_3, p1_0,p1_1,p1_2,p1_3,
                        p2_0,p2_1,p2_2,p2_3, p3_0,p3_1,p3_2,p3_3;

  logic              bc_rd_en;
  logic [ADDR_W-1:0] bc_rd_addr0, bc_rd_addr1, bc_rd_addr2, bc_rd_addr3;
  logic [ADDR_W-1:0] bc_rowbase;
  logic              bc_gather_valid;   // pulses for 1 cycle: taps+weights ready, feed bicubic.sv

  // Row base address for whichever row (relative to the locked anchor)
  // is being read THIS cycle -- row index selected by bcstate.
  logic [COORD_W-1:0] bc_row_y;
  always_comb begin
    unique case (bcstate)
      BC_IDLE: bc_row_y = bcy0_c - 1'b1;         // uses COMBINATIONAL anchor (not yet locked)
      BC_R1:   bc_row_y = bcy0_lock;
      BC_R2:   bc_row_y = bcy0_lock + 1'b1;
      BC_R3:   bc_row_y = bcy0_lock + 1'b1 + 1'b1;
      default: bc_row_y = bcy0_lock;
    endcase
    bc_rowbase = {{(ADDR_W-COORD_W){1'b0}}, bc_row_y} * img_width;
  end

  always_comb begin
    // Column addresses: x0-1,x0,x0+1,x0+2, using combinational anchor
    // while still in BC_IDLE (row0 issue), locked anchor afterward.
    logic [COORD_W-1:0] xb;
    xb = (bcstate == BC_IDLE) ? bcx0_c : bcx0_lock;
    bc_rd_en    = (bcstate == BC_IDLE && cg_valid) || (bcstate == BC_R1) ||
                  (bcstate == BC_R2)                || (bcstate == BC_R3);
    bc_rd_addr0 = bc_rowbase + {{(ADDR_W-COORD_W){1'b0}}, xb} - 1'b1;
    bc_rd_addr1 = bc_rowbase + {{(ADDR_W-COORD_W){1'b0}}, xb};
    bc_rd_addr2 = bc_rowbase + {{(ADDR_W-COORD_W){1'b0}}, xb} + 1'b1;
    bc_rd_addr3 = bc_rowbase + {{(ADDR_W-COORD_W){1'b0}}, xb} + 2'd2;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bcstate <= BC_IDLE;
      bcx0_lock <= '0; bcy0_lock <= '0; bctx_lock <= '0; bcty_lock <= '0;
      {p0_0,p0_1,p0_2,p0_3,p1_0,p1_1,p1_2,p1_3,
       p2_0,p2_1,p2_2,p2_3,p3_0,p3_1,p3_2,p3_3} <= '0;
      bc_gather_valid <= 1'b0;
    end else begin
      bc_gather_valid <= 1'b0;
      unique case (bcstate)
        BC_IDLE: begin
          if (cg_valid) begin
            bcx0_lock <= bcx0_c; bcy0_lock <= bcy0_c;
            bctx_lock <= bctx_c; bcty_lock <= bcty_c;
            bcstate   <= BC_R1;
          end
        end
        BC_R1: begin
          {p0_0,p0_1,p0_2,p0_3} <= {fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3};
          bcstate <= BC_R2;
        end
        BC_R2: begin
          {p1_0,p1_1,p1_2,p1_3} <= {fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3};
          bcstate <= BC_R3;
        end
        BC_R3: begin
          {p2_0,p2_1,p2_2,p2_3} <= {fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3};
          bcstate <= BC_R4;
        end
        BC_R4: begin
          {p3_0,p3_1,p3_2,p3_3} <= {fb_rd_data0, fb_rd_data1, fb_rd_data2, fb_rd_data3};
          bc_gather_valid <= 1'b1;
          bcstate <= BC_IDLE;
        end
        default: bcstate <= BC_IDLE;
      endcase
    end
  end

  logic [PIX_W-1:0] bc_pixel;

  bicubic u_bicubic (
    .clk, .rst_n,
    .valid_in (bc_gather_valid),
    .tx_q16 (bctx_lock), .ty_q16 (bcty_lock),
    .p00(p0_0), .p01(p0_1), .p02(p0_2), .p03(p0_3),
    .p10(p1_0), .p11(p1_1), .p12(p1_2), .p13(p1_3),
    .p20(p2_0), .p21(p2_1), .p22(p2_2), .p23(p2_3),
    .p30(p3_0), .p31(p3_1), .p32(p3_2), .p33(p3_3),
    .valid_out (bc_valid),
    .pixel_out (bc_pixel)
  );

  // ---------------------------------------------------------------------
  // frame_buffer read-port mux: bicubic's sequential row reads when
  // interp_mode=1, bilinear's single-cycle 2x2 read otherwise.
  // ---------------------------------------------------------------------
  assign fb_rd_en    = interp_mode ? bc_rd_en    : bl_rd_en;
  assign fb_rd_addr0 = interp_mode ? bc_rd_addr0 : bl_rd_addr0;
  assign fb_rd_addr1 = interp_mode ? bc_rd_addr1 : bl_rd_addr1;
  assign fb_rd_addr2 = interp_mode ? bc_rd_addr2 : bl_rd_addr2;
  assign fb_rd_addr3 = interp_mode ? bc_rd_addr3 : bl_rd_addr3;

  // ---------------------------------------------------------------------
  // tlast/tuser tag delay line. Fed every cycle by the same req_tlast/
  // req_tuser regardless of mode; each of the FOUR (interp_mode x
  // coord_gen-fast-or-slow) combinations reads back the tap matching its
  // own fixed total latency, all four measured directly in simulation
  // (never hand-derived alone -- see README's account of the bicubic
  // hand-count originally being off by one until checked this way):
  //   TOTAL_LATENCY_BILINEAR         = 13 cycles  (MODEL_RADIAL/AFFINE/SCALING)
  //   TOTAL_LATENCY_BICUBIC          = 19 cycles  (MODEL_RADIAL/AFFINE/SCALING)
  //   TOTAL_LATENCY_BILINEAR_SLOWDIV = 43 cycles  (MODEL_FISHEYE/PANORAMIC/PERSPECTIVE)
  //   TOTAL_LATENCY_BICUBIC_SLOWDIV  = 49 cycles  (MODEL_FISHEYE/PANORAMIC/PERSPECTIVE)
  // The two SLOWDIV figures are coord_gen's own much longer per-pixel-
  // divide latency (see coord_gen.sv's "slow path") in place of its
  // usual 9-cycle fast latency, plus the same downstream bilinear/
  // bicubic latency as the fast case -- but, as with bicubic's own
  // earlier off-by-one, this was confirmed by measurement rather than
  // by adding coord_gen's slow-path cycle count to the fast-path
  // downstream figures by hand (which would have predicted 42 and 48).
  // ---------------------------------------------------------------------
  localparam int TOTAL_LATENCY_BILINEAR         = 13;
  localparam int TOTAL_LATENCY_BICUBIC          = 19;
  localparam int TOTAL_LATENCY_BILINEAR_SLOWDIV = 43;
  localparam int TOTAL_LATENCY_BICUBIC_SLOWDIV  = 49;
  localparam int TAG_SR_DEPTH = 49;
  logic [TAG_SR_DEPTH-1:0] tlast_sr, tuser_sr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tlast_sr <= '0; tuser_sr <= '0;
    end else begin
      tlast_sr <= {tlast_sr[TAG_SR_DEPTH-2:0], req_tlast};
      tuser_sr <= {tuser_sr[TAG_SR_DEPTH-2:0], req_tuser};
    end
  end

  logic [5:0] active_tag_depth;
  always_comb begin
    if (model_is_slow_div) active_tag_depth = interp_mode ? TOTAL_LATENCY_BICUBIC_SLOWDIV : TOTAL_LATENCY_BILINEAR_SLOWDIV;
    else                   active_tag_depth = interp_mode ? TOTAL_LATENCY_BICUBIC         : TOTAL_LATENCY_BILINEAR;
  end

  assign m_axis_tvalid = interp_mode ? bc_valid : bl_valid;
  assign m_axis_tdata   = interp_mode ? bc_pixel : bl_pixel;
  assign m_axis_tlast   = tlast_sr[active_tag_depth-1];
  assign m_axis_tuser   = tuser_sr[active_tag_depth-1];

  // ---------------------------------------------------------------------
  // Output beat counter -> frame_out_done
  // ---------------------------------------------------------------------
  logic [ADDR_W:0] beats_remaining;
  logic             counting;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beats_remaining <= '0; counting <= 1'b0; frame_out_done <= 1'b0;
    end else begin
      frame_out_done <= 1'b0;
      if (start_output) begin
        beats_remaining <= {1'b0, img_width} * {1'b0, img_height};
        counting <= 1'b1;
      end else if (counting && m_axis_tvalid && m_axis_tready) begin
        if (beats_remaining <= 1) begin
          counting       <= 1'b0;
          frame_out_done <= 1'b1;
        end else begin
          beats_remaining <= beats_remaining - 1'b1;
        end
      end
    end
  end
  

endmodule
