// ***************
// Filename: coord_gen.sv
// Author: Paul Barcelona
// Description: Reusable IP. Per-pixel source-address generator. Fast
// fixed-latency path for radial/tangential distortion and the
// affine/scaling hooks; a second "slow path" per-pixel divide
// FSM (reusing fixed_recip) implements fisheye, panoramic, and
// perspective correction.
// Date: September 26, 2026
// ***************
// =============================================================================
// coord_gen.sv
//
// For each output (corrected-image) pixel (x,y), computes the fractional
// source coordinate to sample from the (distorted) input frame. Camera-
// calibration-style pinhole normalization, then (when cfg.model_sel ==
// MODEL_RADIAL) the standard radial+tangential ("plumb bob") distortion
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
// ARCHITECTURE HOOK: when cfg.model_sel != MODEL_RADIAL (i.e. one of the
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
// corresponding output (LATENCY=9, unchanged from before this module
// gained tangential-distortion support -- the new math was folded into
// existing pipeline stages rather than adding new ones; re-confirmed by
// direct measurement, not just by this claim -- see the latency-probe
// methodology described in README.md). This easily meets 100 MHz on any
// modern FPGA (single 32x32 multiply per stage).
// =============================================================================
import barrel_pkg::*;
import distortion_model_pkg::*;

module coord_gen #(
  parameter int COORD_W = barrel_pkg::COORD_W
) (
  input  logic clk,
  input  logic rst_n,

  // Static per-frame configuration (held stable while streaming)
  input  calib_params_t cfg,

  // Per-pixel request
  input  logic                    in_valid,
  input  logic [COORD_W-1:0]      in_x,
  input  logic [COORD_W-1:0]      in_y,

  // Result, LATENCY cycles later
  output logic                    out_valid,
  output logic signed [31:0]      out_sx_q16,   // full Q16.16 source X (pre-split)
  output logic signed [31:0]      out_sy_q16,   // full Q16.16 source Y (pre-split)

  // Asserted while a MODEL_FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE
  // per-pixel divide is in flight (see "slow path" below). Always 0 for
  // MODEL_RADIAL and the two remaining hooks (MODEL_AFFINE/
  // MODEL_SCALING) -- those stay on the original fixed-latency,
  // 1-pixel/clock path, completely unaffected by this. The caller
  // (axis_out_ctrl.sv's raster generator) must not present a new
  // in_valid while busy is high for these three models -- same
  // request-pacing discipline it already uses for bicubic mode.
  output logic                    busy
);

  localparam int LATENCY = 9;

  logic is_radial;
  assign is_radial = (cfg.model_sel == MODEL_RADIAL);

  // Slow path: MODEL_FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE need a
  // per-pixel reciprocal (see distortion_model_pkg.sv header for the
  // math) -- handled by a separate FSM below, entirely independent of
  // the fast fixed-latency v0..v8 pipeline the other three models use.
  logic is_slow_div;
  assign is_slow_div = (cfg.model_sel == MODEL_FISHEYE) ||
                        (cfg.model_sel == MODEL_PANORAMIC) ||
                        (cfg.model_sel == MODEL_PERSPECTIVE);

  // ---- Stage 0: register inputs, compute dx,dy ------------------------
  logic                v0;
  logic signed [31:0]  dx0, dy0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v0 <= 1'b0; dx0 <= '0; dy0 <= '0;
    end else begin
      v0  <= in_valid && !is_slow_div;
      dx0 <= ({{(32-COORD_W){1'b0}}, in_x} <<< FRAC_BITS) - cfg.cx_pix;
      dy0 <= ({{(32-COORD_W){1'b0}}, in_y} <<< FRAC_BITS) - cfg.cy_pix;
    end
  end

  // ---- Stage 1: nx = dx/fx ; ny = dy/fy (via precomputed reciprocal) ---
  logic               v1;
  logic signed [31:0] nx1, ny1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; nx1 <= '0; ny1 <= '0;
    end else begin
      v1  <= v0;
      nx1 <= barrel_pkg::qmul(dx0, $signed({1'b0, cfg.recip_fx}));
      ny1 <= barrel_pkg::qmul(dy0, $signed({1'b0, cfg.recip_fy}));
    end
  end

  // ---- Stage 2: r2 = nx^2+ny^2 ; also carry nx^2,ny^2,nx*ny for the ----
  // tangential-distortion terms computed at stage 5 (avoids recomputing
  // these products later, and avoids a separate parallel pipeline).
  logic               v2;
  logic signed [31:0] nx2, ny2, r2_2, nxsq_2, nysq_2, nxny_2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v2 <= 1'b0; nx2 <= '0; ny2 <= '0; r2_2 <= '0; nxsq_2 <= '0; nysq_2 <= '0; nxny_2 <= '0;
    end else begin
      v2     <= v1;
      nx2    <= nx1;
      ny2    <= ny1;
      nxsq_2 <= barrel_pkg::qmul(nx1, nx1);
      nysq_2 <= barrel_pkg::qmul(ny1, ny1);
      nxny_2 <= barrel_pkg::qmul(nx1, ny1);
      r2_2   <= barrel_pkg::qmul(nx1, nx1) + barrel_pkg::qmul(ny1, ny1);
    end
  end

  // ---- Stage 3: r4 = r2*r2 (carry nx,ny,r2,nx^2,ny^2,nx*ny forward) -----
  logic               v3;
  logic signed [31:0] nx3, ny3, r2_3, r4_3, nxsq_3, nysq_3, nxny_3;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v3 <= 1'b0; nx3 <= '0; ny3 <= '0; r2_3 <= '0; r4_3 <= '0;
      nxsq_3 <= '0; nysq_3 <= '0; nxny_3 <= '0;
    end else begin
      v3     <= v2;
      nx3    <= nx2; ny3 <= ny2; r2_3 <= r2_2;
      nxsq_3 <= nxsq_2; nysq_3 <= nysq_2; nxny_3 <= nxny_2;
      r4_3   <= barrel_pkg::qmul(r2_2, r2_2);
    end
  end

  // ---- Stage 4: r6 = r4*r2 ------------------------------------------------
  logic               v4;
  logic signed [31:0] nx4, ny4, r2_4, r4_4, r6_4, nxsq_4, nysq_4, nxny_4;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v4 <= 1'b0; nx4 <= '0; ny4 <= '0; r2_4 <= '0; r4_4 <= '0; r6_4 <= '0;
      nxsq_4 <= '0; nysq_4 <= '0; nxny_4 <= '0;
    end else begin
      v4     <= v3;
      nx4    <= nx3; ny4 <= ny3; r2_4 <= r2_3; r4_4 <= r4_3;
      nxsq_4 <= nxsq_3; nysq_4 <= nysq_3; nxny_4 <= nxny_3;
      r6_4   <= barrel_pkg::qmul(r4_3, r2_3);
    end
  end

  // ---- Stage 5: t1=k1*r2, t2=k2*r4, t3=k3*r6 ; tangential terms --------
  // ARCHITECTURE HOOK gate: when model_sel != MODEL_RADIAL, all of these
  // (and therefore the radial `factor` computed next stage, and the
  // tangential offset applied two stages later) collapse to the
  // identity values (t1=t2=t3=0 -> factor=1.0 ; tang_x=tang_y=0).
  logic               v5;
  logic signed [31:0] nx5, ny5, t1_5, t2_5, t3_5, tangx_5, tangy_5;
  logic signed [31:0] tang_a, tang_b, tang_c, tang_d;
  always_comb begin
    tang_a = barrel_pkg::qmul(cfg.p1, nxny_4) <<< 1;                    // 2*p1*nx*ny
    tang_b = barrel_pkg::qmul(cfg.p2, r2_4 + (nxsq_4 <<< 1));           // p2*(r2+2nx^2)
    tang_c = barrel_pkg::qmul(cfg.p1, r2_4 + (nysq_4 <<< 1));           // p1*(r2+2ny^2)
    tang_d = barrel_pkg::qmul(cfg.p2, nxny_4) <<< 1;                    // 2*p2*nx*ny
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v5 <= 1'b0; nx5 <= '0; ny5 <= '0; t1_5 <= '0; t2_5 <= '0; t3_5 <= '0;
      tangx_5 <= '0; tangy_5 <= '0;
    end else begin
      v5   <= v4;
      nx5  <= nx4; ny5 <= ny4;
      if (is_radial) begin
        t1_5    <= barrel_pkg::qmul(cfg.k1, r2_4);
        t2_5    <= barrel_pkg::qmul(cfg.k2, r4_4);
        t3_5    <= barrel_pkg::qmul(cfg.k3, r6_4);
        tangx_5 <= tang_a + tang_b;
        tangy_5 <= tang_c + tang_d;
      end else begin
        t1_5 <= '0; t2_5 <= '0; t3_5 <= '0; tangx_5 <= '0; tangy_5 <= '0;
      end
    end
  end

  // ---- Stage 6: factor = 1 + t1 + t2 + t3 ------------------------------
  logic               v6;
  logic signed [31:0] nx6, ny6, factor6, tangx6, tangy6;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v6 <= 1'b0; nx6 <= '0; ny6 <= '0; factor6 <= '0; tangx6 <= '0; tangy6 <= '0;
    end else begin
      v6      <= v5;
      nx6     <= nx5; ny6 <= ny5;
      factor6 <= Q16_ONE + t1_5 + t2_5 + t3_5;
      tangx6  <= tangx_5;
      tangy6  <= tangy_5;
    end
  end

  // ---- Stage 7: sxn = nx*factor + tang_x ; syn = ny*factor + tang_y ----
  logic               v7;
  logic signed [31:0] sxn7, syn7;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v7 <= 1'b0; sxn7 <= '0; syn7 <= '0;
    end else begin
      v7   <= v6;
      sxn7 <= barrel_pkg::qmul(nx6, factor6) + tangx6;
      syn7 <= barrel_pkg::qmul(ny6, factor6) + tangy6;
    end
  end

  // ---- Stage 8: sx = cx + sxn*fx ; sy = cy + syn*fy --------------------
  logic               v8;
  logic signed [31:0] sx8, sy8;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v8 <= 1'b0; sx8 <= '0; sy8 <= '0;
    end else begin
      v8  <= v7;
      sx8 <= cfg.cx_pix + barrel_pkg::qmul(sxn7, cfg.fx_pix);
      sy8 <= cfg.cy_pix + barrel_pkg::qmul(syn7, cfg.fy_pix);
    end
  end

  // =======================================================================
  // SLOW PATH: MODEL_FISHEYE / MODEL_PANORAMIC / MODEL_PERSPECTIVE.
  // One (x,y) request at a time (busy gates the next), one per-pixel
  // reciprocal via a single shared fixed_recip instance. See
  // distortion_model_pkg.sv's header for the exact math each model uses.
  // =======================================================================
  typedef enum logic [2:0] {SD_IDLE, SD_ISSUE, SD_WAIT, SD_DONE} sd_state_t;
  sd_state_t sd_state;

  logic [COORD_W-1:0] sd_x, sd_y;
  logic                sd_recip_start, sd_recip_done, sd_recip_busy;
  logic [31:0]         sd_recip_result;
  logic signed [31:0]  sd_out_sx, sd_out_sy;
  logic                sd_out_valid;

  // nx/ny/denom computation as FUNCTIONS rather than always_comb-driven
  // signals -- called directly wherever needed (fixed_recip's operand
  // port, and the output computation in SD_WAIT below), recomputing
  // small, cheap expressions rather than sharing wires. This is a
  // structural workaround: several different always_comb formulations of
  // this same math (a single case-based block computing all three
  // models' denominators; the three split into per-model always_comb
  // blocks with a separate selector) reproducibly hung Icarus Verilog
  // 12.0 given specific nonzero coefficient combinations (isolated in
  // detail; root cause not identified -- see the project's Icarus-quirks
  // notes in README.md). Functions sidestep whatever internal pattern
  // was triggering it.
  function automatic logic signed [31:0] slow_nx(input calib_params_t c, input logic [COORD_W-1:0] x);
    logic signed [31:0] dxv;
    begin
      dxv = ({{(32-COORD_W){1'b0}}, x} <<< FRAC_BITS) - c.cx_pix;
      slow_nx = barrel_pkg::qmul(dxv, $signed({1'b0, c.recip_fx}));
    end
  endfunction

  function automatic logic signed [31:0] slow_ny(input calib_params_t c, input logic [COORD_W-1:0] y);
    logic signed [31:0] dyv;
    begin
      dyv = ({{(32-COORD_W){1'b0}}, y} <<< FRAC_BITS) - c.cy_pix;
      slow_ny = barrel_pkg::qmul(dyv, $signed({1'b0, c.recip_fy}));
    end
  endfunction

  function automatic logic signed [31:0] slow_xq(input logic [COORD_W-1:0] x);
    slow_xq = {{(32-COORD_W){1'b0}}, x} <<< FRAC_BITS;
  endfunction

  function automatic logic signed [31:0] slow_yq(input logic [COORD_W-1:0] y);
    slow_yq = {{(32-COORD_W){1'b0}}, y} <<< FRAC_BITS;
  endfunction

  function automatic logic signed [31:0] slow_denom_safe(input calib_params_t c,
      input logic [COORD_W-1:0] x, input logic [COORD_W-1:0] y);
    logic signed [31:0] nxv, nyv, r2v, r4v, rawv;
    begin
      nxv = slow_nx(c, x);
      nyv = slow_ny(c, y);
      r2v = barrel_pkg::qmul(nxv, nxv) + barrel_pkg::qmul(nyv, nyv);
      r4v = barrel_pkg::qmul(r2v, r2v);
      if (c.model_sel == MODEL_FISHEYE)
        rawv = Q16_ONE + barrel_pkg::qmul(c.k1, r2v) + barrel_pkg::qmul(c.k2, r4v);
      else if (c.model_sel == MODEL_PANORAMIC)
        rawv = Q16_ONE + barrel_pkg::qmul(c.k1, barrel_pkg::qmul(nxv, nxv));
      else if (c.model_sel == MODEL_PERSPECTIVE)
        rawv = Q16_ONE + barrel_pkg::qmul(c.h31, slow_xq(x)) + barrel_pkg::qmul(c.h32, slow_yq(y));
      else
        rawv = Q16_ONE;
      // Safety clamp: a denominator that hits <=0 (extreme coefficients,
      // or a point near a homography's vanishing line) has no sane
      // finite answer -- fall back to a small positive epsilon rather
      // than feed fixed_recip a value it would otherwise silently
      // reinterpret as unsigned (which, for a negative signed value, is
      // a huge positive number -- a real garbage-in-garbage-out hazard).
      // This is a documented limitation, not full projective clipping.
      slow_denom_safe = (rawv <= 0) ? 32'sh0000_0001 : rawv;
    end
  endfunction

  fixed_recip #(.W(32)) u_slow_recip (
    .clk, .rst_n,
    .start   (sd_recip_start),
    .operand ($unsigned(slow_denom_safe(cfg, sd_x, sd_y))),
    .result  (sd_recip_result),
    .busy    (sd_recip_busy),
    .done    (sd_recip_done)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sd_state <= SD_IDLE;
      sd_x <= '0; sd_y <= '0;
      sd_recip_start <= 1'b0;
      sd_out_sx <= '0; sd_out_sy <= '0; sd_out_valid <= 1'b0;
    end else begin
      sd_recip_start <= 1'b0;
      sd_out_valid   <= 1'b0;
      unique case (sd_state)
        SD_IDLE: begin
          if (is_slow_div && in_valid) begin
            sd_x <= in_x; sd_y <= in_y;
            sd_state <= SD_ISSUE;
          end
        end
        SD_ISSUE: begin
          // sd_x/sd_y now settled; sd_denom_safe (combinational from
          // them) is valid this cycle -- kick off the divide.
          sd_recip_start <= 1'b1;
          sd_state <= SD_WAIT;
        end
        SD_WAIT: begin
          if (sd_recip_done) begin
            unique case (cfg.model_sel)
              MODEL_FISHEYE: begin
                sd_out_sx <= cfg.cx_pix + barrel_pkg::qmul(barrel_pkg::qmul(slow_nx(cfg, sd_x), $signed({1'b0, sd_recip_result})), cfg.fx_pix);
                sd_out_sy <= cfg.cy_pix + barrel_pkg::qmul(barrel_pkg::qmul(slow_ny(cfg, sd_y), $signed({1'b0, sd_recip_result})), cfg.fy_pix);
              end
              MODEL_PANORAMIC: begin
                sd_out_sx <= cfg.cx_pix + barrel_pkg::qmul(barrel_pkg::qmul(slow_nx(cfg, sd_x), $signed({1'b0, sd_recip_result})), cfg.fx_pix);
                sd_out_sy <= cfg.cy_pix + barrel_pkg::qmul(slow_ny(cfg, sd_y), cfg.fy_pix);
              end
              default /* MODEL_PERSPECTIVE */: begin
                sd_out_sx <= barrel_pkg::qmul(
                  barrel_pkg::qmul(cfg.h11, slow_xq(sd_x)) + barrel_pkg::qmul(cfg.h12, slow_yq(sd_y)) + cfg.h13,
                  $signed({1'b0, sd_recip_result}));
                sd_out_sy <= barrel_pkg::qmul(
                  barrel_pkg::qmul(cfg.h21, slow_xq(sd_x)) + barrel_pkg::qmul(cfg.h22, slow_yq(sd_y)) + cfg.h23,
                  $signed({1'b0, sd_recip_result}));
              end
            endcase
            sd_state <= SD_DONE;
          end
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
