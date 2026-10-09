// ***************
// Filename: coord_gen.sv
// Author: FPGA Cores 4 U
// Description: Reusable IP. Per-pixel source-address generator. Fast
// 23-cycle path for radial/tangential distortion and the
// affine/scaling hooks; a second "slow path" per-pixel divide
// FSM (reusing fixed_recip) implements fisheye, panoramic, and
// perspective correction. All multiplies use the mulq_s IP.
// Date: September 26, 2026
// ***************
// =============================================================================
// coord_gen.sv
//
// For each output (corrected-image) pixel (x,y), computes the fractional
// source coordinate to sample from the (distorted) input frame. Camera-
// calibration-style pinhole normalization, then (when cfg.model_sel ==
// distortion_model_pkg::MODEL_RADIAL) the standard radial+tangential ("plumb bob") distortion
// model:
//
//   nx = (x - cx_pix) / fx_pix          -- normalize (pinhole intrinsics)
//   ny = (y - cy_pix) / fy_pix
//   r2 = nx^2 + ny^2
//   radial   = 1 + k1*r2 + k2*r2^2 + k3*r2^3        (k3 * r^6 term)
//   tang_x   = 2*p1*nx*ny + p2*(r2 + 2*nx^2)
//   tang_y   =   p1*(r2 + 2*ny^2) + 2*p2*nx*ny
//   sx = cx_pix + (nx*radial + tang_x) * fx_pix
//   sy = cy_pix + (ny*radial + tang_y) * fy_pix
//
// cfg (calib_params_t, distortion_model_pkg.sv) bundles every one of the
// above parameters into a single struct port -- see that package for why.
//
// ARCHITECTURE HOOK: when cfg.model_sel != distortion_model_pkg::MODEL_RADIAL (i.e. one of the
// reserved FISHEYE/AFFINE/PERSPECTIVE/SCALING/PANORAMIC slots), the k1/k2/k3/p1/p2
// contributions are gated to zero right where they're computed (stage 5
// below) rather than being threaded through extra "is this the active
// model" muxing at every later stage -- radial=1.0, tangential=0 falls
// straight out of the existing math with no separate identity datapath,
// so this reduces to the same normalize/denormalize round-trip the
// current pinhole intrinsics already define (matches the golden models'
// identity-passthrough for these model IDs bit-for-bit -- see the
// project's smoke test). Implementing an actual FISHEYE/AFFINE/
// PERSPECTIVE/SCALING projection means replacing this gate with real
// per-model math -- see README.md "Extension hooks" for the equations
// and where each would plug in.
//
// All arithmetic is Q16.16 (see barrel_pkg). This is a fully pipelined,
// feed-forward (no feedback/stall) datapath: one (x,y) request may be
// accepted every clock cycle, with a fixed LATENCY-cycle delay to the
// corresponding output (LATENCY=23 since the timing work: every multiply
// goes through the mulq_s IP -- it was 9 with one single-cycle qmul per
// stage. Confirmed by direct measurement -- see the latency-probe
// methodology described in README.md).
//
// TIMING: an earlier revision of this comment claimed the design "easily
// meets 100 MHz (single 32x32 multiply per stage)". That was wrong: a
// one-cycle 32x32 multiply plus its shift/saturate/add is ~11 ns of
// logic on 7-series, and the slow path chained five of them. Measured
// with synth/est_timing.py the worst path was ~48 ns. After the timing
// work it is ~6.5 ns in this module (~7.2 ns in mulq_s) -- see README.
// =============================================================================

module coord_gen #(
  parameter int COORD_W = barrel_pkg::COORD_W
) (
  input  logic clk,
  input  logic rst_n,

  // Static per-frame configuration (held stable while streaming)
  input  distortion_model_pkg::calib_params_t cfg,

  // Per-pixel request
  input  logic                    in_valid,
  input  logic [COORD_W-1:0]      in_x,
  input  logic [COORD_W-1:0]      in_y,

  // Result, LATENCY cycles later
  output logic                    out_valid,
  output logic signed [31:0]      out_sx_q16,   // full Q16.16 source X (pre-split)
  output logic signed [31:0]      out_sy_q16,   // full Q16.16 source Y (pre-split)

  // Asserted while a distortion_model_pkg::MODEL_FISHEYE/distortion_model_pkg::MODEL_PANORAMIC/distortion_model_pkg::MODEL_PERSPECTIVE
  // per-pixel divide is in flight (see "slow path" below). Always 0 for
  // distortion_model_pkg::MODEL_RADIAL and the two remaining hooks (distortion_model_pkg::MODEL_AFFINE/
  // distortion_model_pkg::MODEL_SCALING) -- those stay on the original fixed-latency,
  // 1-pixel/clock path, completely unaffected by this. The caller
  // (axis_out_ctrl.sv's raster generator) must not present a new
  // in_valid while busy is high for these three models -- same
  // request-pacing discipline it already uses for bicubic mode.
  output logic                    busy
);

  localparam int LATENCY = 23;

  logic is_radial;
  assign is_radial = (cfg.model_sel == distortion_model_pkg::MODEL_RADIAL);

  // Slow path: distortion_model_pkg::MODEL_FISHEYE/distortion_model_pkg::MODEL_PANORAMIC/distortion_model_pkg::MODEL_PERSPECTIVE need a
  // per-pixel reciprocal (see distortion_model_pkg.sv header for the
  // math) -- handled by a separate FSM below, entirely independent of
  // the fast fixed-latency v0..v8 pipeline the other three models use.
  logic is_slow_div;
  assign is_slow_div = (cfg.model_sel == distortion_model_pkg::MODEL_FISHEYE) ||
                        (cfg.model_sel == distortion_model_pkg::MODEL_PANORAMIC) ||
                        (cfg.model_sel == distortion_model_pkg::MODEL_PERSPECTIVE);

  // =======================================================================
  // TIMING NOTE (pipeline structure, LATENCY 23)
  //
  // Every multiply goes through the mulq_s IP (2 cycles: 16x16 DSP partial
  // products registered inside the DSPs, then combined into the exact
  // 48-bit (a*b)>>>16), followed by one register stage that saturates
  // (barrel_pkg::qsat48) and does any small add. qsat48(mulq_s(a,b)) is
  // exactly barrel_pkg::qmul(a,b), so results are bit-identical to the
  // original single-cycle formulation -- only registers were added.
  // Data registers carry no reset (only the valid bits do): an async
  // reset on a datapath register prevents DSP-register packing and costs
  // an inverter per flop. Their contents are meaningless until valid.
  //
  // Each "multiply stage" below is therefore 3 register levels: two inside
  // mulq_s, one saturate/add. Side-band values that must stay aligned with
  // a multiply's result are delayed by the same 2 cycles.
  // =======================================================================

  // Signed views of the unsigned reciprocals (intermediate wires, not
  // $signed() in port connections: Yosys 0.33 frontend signedness bug).
  // Reinterpreting the 32-bit reciprocal as signed matches the original
  // qmul(.., $signed({1'b0, recip})) which truncated to 32 bits.
  logic signed [31:0] recip_fx_s, recip_fy_s;
  assign recip_fx_s = cfg.recip_fx;
  assign recip_fy_s = cfg.recip_fy;

  // ---- valid pipeline: 23 stages, aligned with the datapath below -------
  logic [22:0] vpipe;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vpipe <= '0;
    else        vpipe <= {vpipe[21:0], in_valid && !is_slow_div};
  end
  logic v8;
  assign v8 = vpipe[22];

  // ---- Stage 0 (level 1): dx, dy ----------------------------------------
  logic signed [31:0] dx0, dy0;
  always_ff @(posedge clk) begin
    dx0 <= ({{(32-COORD_W){1'b0}}, in_x} <<< barrel_pkg::FRAC_BITS) - cfg.cx_pix;
    dy0 <= ({{(32-COORD_W){1'b0}}, in_y} <<< barrel_pkg::FRAC_BITS) - cfg.cy_pix;
  end

  // ---- Stage 1 (levels 2-4): nx = dx/fx ; ny = dy/fy --------------------
  logic signed [47:0] fm_nx1, fm_ny1;
  logic signed [31:0] nx1, ny1;
  mulq_s u_m_nx (
    .clk,
    .a(dx0),
    .b(recip_fx_s),
    .s(fm_nx1)
  );
  mulq_s u_m_ny (
    .clk,
    .a(dy0),
    .b(recip_fy_s),
    .s(fm_ny1)
  );
  always_ff @(posedge clk) begin
    nx1 <= barrel_pkg::qsat48(fm_nx1);
    ny1 <= barrel_pkg::qsat48(fm_ny1);
  end

  // ---- Stage 2 (levels 5-7): nx^2, ny^2, nx*ny, r2 = nx^2+ny^2 ----------
  // (nx,ny,nx^2,ny^2,nx*ny carried forward for the tangential terms.)
  logic signed [47:0] fm_nxsq, fm_nysq, fm_nxny;
  logic signed [31:0] nx2a, nx2b, ny2a, ny2b;
  logic signed [31:0] nx2, ny2, r2_2, nxsq_2, nysq_2, nxny_2;
  mulq_s u_m_nxsq (
    .clk,
    .a(nx1),
    .b(nx1),
    .s(fm_nxsq)
  );
  mulq_s u_m_nysq (
    .clk,
    .a(ny1),
    .b(ny1),
    .s(fm_nysq)
  );
  mulq_s u_m_nxny (
    .clk,
    .a(nx1),
    .b(ny1),
    .s(fm_nxny)
  );
  always_ff @(posedge clk) begin
    nx2a <= nx1;
    nx2b <= nx2a;
    ny2a <= ny1;
    ny2b <= ny2a;
    nxsq_2 <= barrel_pkg::qsat48(fm_nxsq);
    nysq_2 <= barrel_pkg::qsat48(fm_nysq);
    nxny_2 <= barrel_pkg::qsat48(fm_nxny);
    r2_2   <= barrel_pkg::qsat48(fm_nxsq) + barrel_pkg::qsat48(fm_nysq);
    nx2    <= nx2b;
    ny2    <= ny2b;
  end

  // ---- Stage 3 (levels 8-10): r4 = r2*r2 ---------------------------------
  logic signed [47:0] fm_r4;
  logic signed [31:0] nx3a, nx3b, ny3a, ny3b, r2_3a, r2_3b, nxsq_3a, nxsq_3b, nysq_3a, nysq_3b, nxny_3a, nxny_3b;
  logic signed [31:0] nx3, ny3, r2_3, r4_3, nxsq_3, nysq_3, nxny_3;
  mulq_s u_m_r4 (
    .clk,
    .a(r2_2),
    .b(r2_2),
    .s(fm_r4)
  );
  always_ff @(posedge clk) begin
    nx3a <= nx2;
    nx3b <= nx3a;
    ny3a <= ny2;
    ny3b <= ny3a;
    r2_3a <= r2_2;
    r2_3b <= r2_3a;
    nxsq_3a <= nxsq_2;
    nxsq_3b <= nxsq_3a;
    nysq_3a <= nysq_2;
    nysq_3b <= nysq_3a;
    nxny_3a <= nxny_2;
    nxny_3b <= nxny_3a;
    r4_3   <= barrel_pkg::qsat48(fm_r4);
    nx3 <= nx3b;
    ny3 <= ny3b;
    r2_3 <= r2_3b;
    nxsq_3 <= nxsq_3b;
    nysq_3 <= nysq_3b;
    nxny_3 <= nxny_3b;
  end

  // ---- Stage 4 (levels 11-13): r6 = r4*r2 ; pre-add the two tangential
  // (r2 + 2n^2) sums so the stage-5 multiplies take registered operands --
  logic signed [47:0] fm_r6;
  logic signed [31:0] nx4a, nx4b, ny4a, ny4b, r2_4a, r2_4b, r4_4a, r4_4b, nxny_4a, nxny_4b;
  logic signed [31:0] sumb_4a, sumb_4b, sumc_4a, sumc_4b;
  logic signed [31:0] nx4, ny4, r2_4, r4_4, r6_4, nxny_4, sumb_4, sumc_4;
  mulq_s u_m_r6 (
    .clk,
    .a(r4_3),
    .b(r2_3),
    .s(fm_r6)
  );
  always_ff @(posedge clk) begin
    nx4a <= nx3;
    nx4b <= nx4a;
    ny4a <= ny3;
    ny4b <= ny4a;
    r2_4a <= r2_3;
    r2_4b <= r2_4a;
    r4_4a <= r4_3;
    r4_4b <= r4_4a;
    nxny_4a <= nxny_3;
    nxny_4b <= nxny_4a;
    sumb_4a <= r2_3 + (nxsq_3 <<< 1);          // r2 + 2nx^2
    sumc_4a <= r2_3 + (nysq_3 <<< 1);          // r2 + 2ny^2
    sumb_4b <= sumb_4a;
    sumc_4b <= sumc_4a;
    r6_4   <= barrel_pkg::qsat48(fm_r6);
    nx4 <= nx4b;
    ny4 <= ny4b;
    r2_4 <= r2_4b;
    r4_4 <= r4_4b;
    nxny_4 <= nxny_4b;
    sumb_4 <= sumb_4b;
    sumc_4 <= sumc_4b;
  end

  // ---- Stage 5 (levels 14-16): t1=k1*r2, t2=k2*r4, t3=k3*r6 ; tangential
  // ARCHITECTURE HOOK gate: when model_sel != MODEL_RADIAL, all of these
  // (and therefore the radial `factor` computed next stage, and the
  // tangential offset applied two stages later) collapse to the
  // identity values (t1=t2=t3=0 -> factor=1.0 ; tang_x=tang_y=0).
  logic signed [47:0] fm_t1, fm_t2, fm_t3, fm_ta, fm_tb, fm_tc, fm_td;
  logic signed [31:0] nx5a, nx5b, ny5a, ny5b;
  logic signed [31:0] nx5, ny5, t1_5, t2_5, t3_5, tangx_5, tangy_5;
  mulq_s u_m_t1 (
    .clk,
    .a(cfg.k1),
    .b(r2_4),
    .s(fm_t1)
  );
  mulq_s u_m_t2 (
    .clk,
    .a(cfg.k2),
    .b(r4_4),
    .s(fm_t2)
  );
  mulq_s u_m_t3 (
    .clk,
    .a(cfg.k3),
    .b(r6_4),
    .s(fm_t3)
  );
  mulq_s u_m_ta (
    .clk,
    .a(cfg.p1),
    .b(nxny_4),
    .s(fm_ta)
  );   // -> 2*p1*nx*ny
  mulq_s u_m_tb (
    .clk,
    .a(cfg.p2),
    .b(sumb_4),
    .s(fm_tb)
  );   // -> p2*(r2+2nx^2)
  mulq_s u_m_tc (
    .clk,
    .a(cfg.p1),
    .b(sumc_4),
    .s(fm_tc)
  );   // -> p1*(r2+2ny^2)
  mulq_s u_m_td (
    .clk,
    .a(cfg.p2),
    .b(nxny_4),
    .s(fm_td)
  );   // -> 2*p2*nx*ny
  always_ff @(posedge clk) begin
    nx5a <= nx4;
    nx5b <= nx5a;
    ny5a <= ny4;
    ny5b <= ny5a;
    nx5 <= nx5b;
    ny5 <= ny5b;
    if (is_radial) begin
      t1_5    <= barrel_pkg::qsat48(fm_t1);
      t2_5    <= barrel_pkg::qsat48(fm_t2);
      t3_5    <= barrel_pkg::qsat48(fm_t3);
      tangx_5 <= (barrel_pkg::qsat48(fm_ta) <<< 1) + barrel_pkg::qsat48(fm_tb);
      tangy_5 <= barrel_pkg::qsat48(fm_tc) + (barrel_pkg::qsat48(fm_td) <<< 1);
    end else begin
      t1_5 <= '0;
      t2_5 <= '0;
      t3_5 <= '0;
      tangx_5 <= '0;
      tangy_5 <= '0;
    end
  end

  // ---- Stage 6 (level 17): factor = 1 + t1 + t2 + t3 (adds only) --------
  logic signed [31:0] nx6, ny6, factor6, tangx6, tangy6;
  always_ff @(posedge clk) begin
    nx6     <= nx5;
    ny6 <= ny5;
    factor6 <= barrel_pkg::Q16_ONE + t1_5 + t2_5 + t3_5;
    tangx6  <= tangx_5;
    tangy6  <= tangy_5;
  end

  // ---- Stage 7 (levels 18-20): sxn = nx*factor + tang_x ; syn similarly --
  logic signed [47:0] fm_sx, fm_sy;
  logic signed [31:0] tangx7a, tangx7b, tangy7a, tangy7b, sxn7, syn7;
  mulq_s u_m_sx (
    .clk,
    .a(nx6),
    .b(factor6),
    .s(fm_sx)
  );
  mulq_s u_m_sy (
    .clk,
    .a(ny6),
    .b(factor6),
    .s(fm_sy)
  );
  always_ff @(posedge clk) begin
    tangx7a <= tangx6;
    tangx7b <= tangx7a;
    tangy7a <= tangy6;
    tangy7b <= tangy7a;
    sxn7 <= barrel_pkg::qsat48(fm_sx) + tangx7b;
    syn7 <= barrel_pkg::qsat48(fm_sy) + tangy7b;
  end

  // ---- Stage 8 (levels 21-23): sx = cx + sxn*fx ; sy = cy + syn*fy -------
  logic signed [47:0] fm_fx, fm_fy;
  logic signed [31:0] sx8, sy8;
  mulq_s u_m_fx (
    .clk,
    .a(sxn7),
    .b(cfg.fx_pix),
    .s(fm_fx)
  );
  mulq_s u_m_fy (
    .clk,
    .a(syn7),
    .b(cfg.fy_pix),
    .s(fm_fy)
  );
  always_ff @(posedge clk) begin
    sx8 <= cfg.cx_pix + barrel_pkg::qsat48(fm_fx);
    sy8 <= cfg.cy_pix + barrel_pkg::qsat48(fm_fy);
  end

  // =======================================================================
  // SLOW PATH: MODEL_FISHEYE / MODEL_PANORAMIC / MODEL_PERSPECTIVE.
  // One (x,y) request at a time (busy gates the next), one per-pixel
  // reciprocal via a single shared fixed_recip instance. See
  // distortion_model_pkg.sv's header for the exact math each model uses.
  //
  // Structure: the request coordinates are latched (sd_x/sd_y) and then
  // HELD for the whole operation, which lets the arithmetic be plain
  // free-running register pipelines fed by those held values:
  //   PRE  pipeline:  sd_x,sd_y -> denominator      (14 register levels)
  //   fixed_recip:    denominator -> 1/denominator  (33+ cycles, iterative)
  //   POST pipeline:  1/denominator -> sx,sy        (6 register levels)
  // The FSM does no arithmetic; it only waits fixed pipeline depths.
  // (Earlier revisions computed the whole denominator -- five chained
  // 32x32 multiplies -- combinationally in one cycle; that was the
  // critical path of the whole design.)
  // =======================================================================
  localparam int SD_PRE_CYCLES  = 16;   // >= register depth of PRE pipeline (14)
  localparam int SD_POST_CYCLES = 8;    // >= register depth of POST pipeline (6)

  typedef enum logic [2:0] {SD_IDLE, SD_PRE, SD_ISSUE, SD_WAIT, SD_POST, SD_DONE} sd_state_t;
  sd_state_t sd_state;
  logic [4:0] sd_cnt;

  logic [COORD_W-1:0] sd_x, sd_y;
  logic               sd_recip_start, sd_recip_done, sd_recip_busy;
  logic [31:0]        sd_recip_result;
  logic signed [31:0] sd_out_sx, sd_out_sy;
  logic               sd_out_valid;

  // ---- PRE pipeline ------------------------------------------------------
  // L1: pixel-coordinate deltas and Q16.16 coordinates
  logic signed [31:0] s_dx, s_dy, s_xq, s_yq;
  always_ff @(posedge clk) begin
    s_dx <= ({{(32-COORD_W){1'b0}}, sd_x} <<< barrel_pkg::FRAC_BITS) - cfg.cx_pix;
    s_dy <= ({{(32-COORD_W){1'b0}}, sd_y} <<< barrel_pkg::FRAC_BITS) - cfg.cy_pix;
    s_xq <= {{(32-COORD_W){1'b0}}, sd_x} <<< barrel_pkg::FRAC_BITS;
    s_yq <= {{(32-COORD_W){1'b0}}, sd_y} <<< barrel_pkg::FRAC_BITS;
  end
  // L2-L4: nx,ny (fisheye/panoramic) and the perspective h-terms
  logic signed [47:0] sm_nx, sm_ny, sm_h31, sm_h32, sm_h11, sm_h12, sm_h21, sm_h22;
  logic signed [31:0] s_nx, s_ny, s_hx, s_hy, s_numx, s_numy;
  mulq_s u_p_nx  (
    .clk,
    .a(s_dx),
    .b(recip_fx_s),
    .s(sm_nx)
  );
  mulq_s u_p_ny  (
    .clk,
    .a(s_dy),
    .b(recip_fy_s),
    .s(sm_ny)
  );
  mulq_s u_p_h31 (
    .clk,
    .a(cfg.h31),
    .b(s_xq),
    .s(sm_h31)
  );
  mulq_s u_p_h32 (
    .clk,
    .a(cfg.h32),
    .b(s_yq),
    .s(sm_h32)
  );
  mulq_s u_p_h11 (
    .clk,
    .a(cfg.h11),
    .b(s_xq),
    .s(sm_h11)
  );
  mulq_s u_p_h12 (
    .clk,
    .a(cfg.h12),
    .b(s_yq),
    .s(sm_h12)
  );
  mulq_s u_p_h21 (
    .clk,
    .a(cfg.h21),
    .b(s_xq),
    .s(sm_h21)
  );
  mulq_s u_p_h22 (
    .clk,
    .a(cfg.h22),
    .b(s_yq),
    .s(sm_h22)
  );
  always_ff @(posedge clk) begin
    s_nx   <= barrel_pkg::qsat48(sm_nx);
    s_ny   <= barrel_pkg::qsat48(sm_ny);
    s_hx   <= barrel_pkg::qsat48(sm_h31);
    s_hy   <= barrel_pkg::qsat48(sm_h32);
    s_numx <= barrel_pkg::qsat48(sm_h11) + barrel_pkg::qsat48(sm_h12) + cfg.h13;
    s_numy <= barrel_pkg::qsat48(sm_h21) + barrel_pkg::qsat48(sm_h22) + cfg.h23;
  end
  // L5-L7: nx^2, ny^2, r2
  logic signed [47:0] sm_nxsq, sm_nysq;
  logic signed [31:0] s_nxsq, s_r2;
  mulq_s u_p_nxsq (
    .clk,
    .a(s_nx),
    .b(s_nx),
    .s(sm_nxsq)
  );
  mulq_s u_p_nysq (
    .clk,
    .a(s_ny),
    .b(s_ny),
    .s(sm_nysq)
  );
  always_ff @(posedge clk) begin
    s_nxsq <= barrel_pkg::qsat48(sm_nxsq);
    s_r2   <= barrel_pkg::qsat48(sm_nxsq) + barrel_pkg::qsat48(sm_nysq);
  end
  // L8-L10: r4 = r2^2 ; k1*r2 ; k1*nx^2
  logic signed [47:0] sm_r4, sm_k1r2, sm_k1nxsq;
  logic signed [31:0] s_r4, s_k1r2, s_k1nxsq;
  mulq_s u_p_r4     (
    .clk,
    .a(s_r2),
    .b(s_r2),
    .s(sm_r4)
  );
  mulq_s u_p_k1r2   (
    .clk,
    .a(cfg.k1),
    .b(s_r2),
    .s(sm_k1r2)
  );
  mulq_s u_p_k1nxsq (
    .clk,
    .a(cfg.k1),
    .b(s_nxsq),
    .s(sm_k1nxsq)
  );
  always_ff @(posedge clk) begin
    s_r4     <= barrel_pkg::qsat48(sm_r4);
    s_k1r2   <= barrel_pkg::qsat48(sm_k1r2);
    s_k1nxsq <= barrel_pkg::qsat48(sm_k1nxsq);
  end
  // L11-L13: k2*r4
  logic signed [47:0] sm_k2r4;
  logic signed [31:0] s_k2r4;
  mulq_s u_p_k2r4 (
    .clk,
    .a(cfg.k2),
    .b(s_r4),
    .s(sm_k2r4)
  );
  always_ff @(posedge clk) s_k2r4 <= barrel_pkg::qsat48(sm_k2r4);
  // L14: model-specific denominator with the <=0 safety clamp.
  // Safety clamp: a denominator that hits <=0 (extreme coefficients, or
  // a point near a homography's vanishing line) has no sane finite
  // answer -- fall back to a small positive epsilon rather than feed
  // fixed_recip a value it would otherwise silently reinterpret as
  // unsigned (a huge positive number -- a garbage-in-garbage-out hazard).
  // This is a documented limitation, not full projective clipping.
  logic signed [31:0] s_raw, s_denom;
  always_comb begin
    if (cfg.model_sel == distortion_model_pkg::MODEL_FISHEYE)
      s_raw = barrel_pkg::Q16_ONE + s_k1r2 + s_k2r4;
    else if (cfg.model_sel == distortion_model_pkg::MODEL_PANORAMIC)
      s_raw = barrel_pkg::Q16_ONE + s_k1nxsq;
    else if (cfg.model_sel == distortion_model_pkg::MODEL_PERSPECTIVE)
      s_raw = barrel_pkg::Q16_ONE + s_hx + s_hy;
    else
      s_raw = barrel_pkg::Q16_ONE;
  end
  always_ff @(posedge clk)
    s_denom <= (s_raw <= 0) ? 32'sh0000_0001 : s_raw;

  // Unsigned view of the denominator for fixed_recip's operand port
  // (an intermediate plain wire, not $unsigned() written in the port
  // connection -- Yosys 0.33 frontend signedness bug).
  logic [31:0] sd_denom_u;
  assign sd_denom_u = s_denom;

  fixed_recip #(.W(32)) u_slow_recip (
    .clk,
    .rst_n,
    .start   (sd_recip_start),
    .operand (sd_denom_u),
    .result  (sd_recip_result),
    .busy    (sd_recip_busy),
    .done    (sd_recip_done)
  );

  // ---- POST pipeline (inputs: held s_* values + the recip result) -------
  // Q1 (3 levels): multiply by 1/denominator ; Q2 (3 levels): scale by
  // fx/fy and add the centre ; the last stage also does the model select.
  logic signed [31:0] sd_recip_s;
  assign sd_recip_s = sd_recip_result;
  logic signed [47:0] sq_ax, sq_ay, sq_px, sq_py, sq_bx, sq_by, sq_pany;
  logic signed [31:0] q_ax, q_ay, q_px, q_py;
  logic signed [31:0] post_sx, post_sy;
  mulq_s u_q_ax (
    .clk,
    .a(s_nx),
    .b(sd_recip_s),
    .s(sq_ax)
  );
  mulq_s u_q_ay (
    .clk,
    .a(s_ny),
    .b(sd_recip_s),
    .s(sq_ay)
  );
  mulq_s u_q_px (
    .clk,
    .a(s_numx),
    .b(sd_recip_s),
    .s(sq_px)
  );
  mulq_s u_q_py (
    .clk,
    .a(s_numy),
    .b(sd_recip_s),
    .s(sq_py)
  );
  always_ff @(posedge clk) begin
    q_ax <= barrel_pkg::qsat48(sq_ax);
    q_ay <= barrel_pkg::qsat48(sq_ay);
    q_px <= barrel_pkg::qsat48(sq_px);
    q_py <= barrel_pkg::qsat48(sq_py);
  end
  mulq_s u_q_bx   (
    .clk,
    .a(q_ax),
    .b(cfg.fx_pix),
    .s(sq_bx)
  );
  mulq_s u_q_by   (
    .clk,
    .a(q_ay),
    .b(cfg.fy_pix),
    .s(sq_by)
  );
  mulq_s u_q_pany (
    .clk,
    .a(s_ny),
    .b(cfg.fy_pix),
    .s(sq_pany)
  );   // panoramic: y not divided
  always_ff @(posedge clk) begin
    if (cfg.model_sel == distortion_model_pkg::MODEL_PERSPECTIVE) begin
      post_sx <= q_px;
      post_sy <= q_py;
    end else begin
      post_sx <= cfg.cx_pix + barrel_pkg::qsat48(sq_bx);
      post_sy <= (cfg.model_sel == distortion_model_pkg::MODEL_PANORAMIC)
                   ? cfg.cy_pix + barrel_pkg::qsat48(sq_pany)
                   : cfg.cy_pix + barrel_pkg::qsat48(sq_by);
    end
  end
  assign sd_out_sx = post_sx;
  assign sd_out_sy = post_sy;

  // ---- FSM: only sequencing / fixed waits, no arithmetic ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sd_state <= SD_IDLE;
      sd_x <= '0;
      sd_y <= '0;
      sd_cnt <= '0;
      sd_recip_start <= 1'b0;
      sd_out_valid <= 1'b0;
    end else begin
      sd_recip_start <= 1'b0;
      sd_out_valid   <= 1'b0;
      unique case (sd_state)
        SD_IDLE: begin
          if (is_slow_div && in_valid) begin
            sd_x <= in_x;
            sd_y <= in_y;
            sd_cnt <= '0;
            sd_state <= SD_PRE;
          end
        end
        SD_PRE: begin                      // let the PRE pipeline fill
          if (sd_cnt == SD_PRE_CYCLES - 1) sd_state <= SD_ISSUE;
          else                             sd_cnt <= sd_cnt + 1'b1;
        end
        SD_ISSUE: begin                    // denominator settled: divide
          sd_recip_start <= 1'b1;
          sd_state <= SD_WAIT;
        end
        SD_WAIT: begin
          if (sd_recip_done) begin
            sd_cnt <= '0;
            sd_state <= SD_POST;
          end
        end
        SD_POST: begin                     // let the POST pipeline fill
          if (sd_cnt == SD_POST_CYCLES - 1) sd_state <= SD_DONE;
          else                              sd_cnt <= sd_cnt + 1'b1;
        end
        SD_DONE: begin
          sd_out_valid <= 1'b1;
          sd_state <= SD_IDLE;
        end
        default: sd_state <= SD_IDLE;
      endcase
    end
  end

  assign busy = is_slow_div && (sd_state != SD_IDLE);

  assign out_valid  = is_slow_div ? sd_out_valid : v8;
  assign out_sx_q16 = is_slow_div ? sd_out_sx    : sx8;
  assign out_sy_q16 = is_slow_div ? sd_out_sy    : sy8;

endmodule
