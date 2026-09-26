// ***************
// Filename: golden_model_pkg.sv
// Author: Paul Barcelona
// Description: Independent, from-scratch SystemVerilog golden-model
// package: fixed-point radial/tangential/fisheye/panoramic/
// perspective remap, bilinear/bicubic sampling, coefficient
// fitting (least-squares and grid search), homography inverse,
// and synthetic chart generation.
// Date: September 26, 2026
// ***************
// =============================================================================
// golden_model_pkg.sv
//
// An INDEPENDENT (separately written, not shared/imported from the RTL)
// reimplementation of the same Q16.16 fixed-point radial-remap primitive
// the RTL (barrel_pkg::qmul + coord_gen + axis_out_ctrl's clamp logic +
// bilinear.sv) implements, used both to synthesize warped.ppm from the
// original image and as the golden bit-exact reference that the DUT's
// streamed output is checked against.
//
// This is deliberately a second, from-scratch implementation (not a
// wrapper around the RTL modules) -- reusing the DUT's own qmul/recip
// would make the "self-check" circular and unable to catch bugs in
// those primitives.
// =============================================================================
package golden_model_pkg;

  localparam int FRAC_BITS = 16;
  localparam longint ONE_Q16 = 32'h0001_0000;

  // 32x32->64 signed multiply, arithmetic shift right 16, saturate to 32 bits.
  function automatic longint qmul_ref(input longint a, input longint b);
    longint prod;
    begin
      prod = (a * b) >>> FRAC_BITS;
      if (prod > 64'sh0000_0000_7FFF_FFFF) prod = 64'sh0000_0000_7FFF_FFFF;
      if (prod < -64'sh0000_0000_8000_0000) prod = -64'sh0000_0000_8000_0000;
      qmul_ref = prod;
    end
  endfunction

  // Unsigned reciprocal: floor(2^32 / operand), operand a positive Q16.16
  // value. A plain integer divide is fine here -- this is testbench code,
  // not required to be synthesizable, and it is written independently of
  // fixed_recip.sv's iterative shift/subtract implementation.
  function automatic longint recip_ref(input longint operand);
    longint op, q;
    begin
      op = (operand <= 0) ? 1 : operand;
      q = (64'sh1_0000_0000) / op;
      if (q > 64'shFFFF_FFFF) q = 64'shFFFF_FFFF;
      recip_ref = q;
    end
  endfunction

  function automatic int bits_ref(input longint v, input int hi, input int lo);
    longint uv;
    begin
      uv = v & 64'hFFFF_FFFF;
      bits_ref = (uv >> lo) & ((1 << (hi - lo + 1)) - 1);
    end
  endfunction

  typedef struct packed {
    int    w, h;
    longint cx_pix, cy_pix;
    longint halfw_scaled, halfh_scaled;
    longint recip_halfw, recip_halfh;
  } remap_cfg_t;

  function automatic remap_cfg_t make_remap_cfg(
    input int w, input int h,
    input longint center_x_q16, input longint center_y_q16, input longint scale_q16
  );
    remap_cfg_t cfg;
    longint imgw_q16, imgh_q16;
    begin
      cfg.w = w; cfg.h = h;
      imgw_q16 = longint'(w) <<< FRAC_BITS;
      imgh_q16 = longint'(h) <<< FRAC_BITS;
      cfg.cx_pix       = qmul_ref(center_x_q16, imgw_q16);
      cfg.cy_pix       = qmul_ref(center_y_q16, imgh_q16);
      cfg.halfw_scaled = qmul_ref(qmul_ref(imgw_q16, 32'h0000_8000), scale_q16);
      cfg.halfh_scaled = qmul_ref(qmul_ref(imgh_q16, 32'h0000_8000), scale_q16);
      cfg.recip_halfw  = recip_ref(cfg.halfw_scaled);
      cfg.recip_halfh  = recip_ref(cfg.halfh_scaled);
      make_remap_cfg = cfg;
    end
  endfunction

  // Applies the radial remap to src (w*h, r/g/b dynamic arrays), bit-exact
  // reproduction of coord_gen + axis_out_ctrl's addressing/clamp logic +
  // bilinear.sv, writing into freshly-allocated out_r/g/b (same w*h).
  task automatic radial_remap_ref(
    input  remap_cfg_t cfg,
    input  longint      k1_q16, input longint k2_q16, input longint k3_q16,
    input  logic [7:0] src_r[], input logic [7:0] src_g[], input logic [7:0] src_b[],
    output logic [7:0] out_r[], output logic [7:0] out_g[], output logic [7:0] out_b[]
  );
    int x, y, x0, y0, fx, fy;
    longint dx, dy, nx, ny, r2, r4, r6, t1, t2, t3, factor, sxn, syn, sx, sy, x0s, y0s;
    int idx_tl, idx_tr, idx_bl, idx_br;
    longint w00, w10, w01, w11, acc;
    begin
      out_r = new[cfg.w * cfg.h];
      out_g = new[cfg.w * cfg.h];
      out_b = new[cfg.w * cfg.h];

      for (y = 0; y < cfg.h; y = y + 1) begin
        dy = (longint'(y) <<< FRAC_BITS) - cfg.cy_pix;
        ny = qmul_ref(dy, cfg.recip_halfh);
        for (x = 0; x < cfg.w; x = x + 1) begin
          dx = (longint'(x) <<< FRAC_BITS) - cfg.cx_pix;
          nx = qmul_ref(dx, cfg.recip_halfw);

          r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);
          r4 = qmul_ref(r2, r2);
          r6 = qmul_ref(r4, r2);
          t1 = qmul_ref(k1_q16, r2);
          t2 = qmul_ref(k2_q16, r4);
          t3 = qmul_ref(k3_q16, r6);
          factor = ONE_Q16 + t1 + t2 + t3;

          sxn = qmul_ref(nx, factor);
          syn = qmul_ref(ny, factor);
          sx  = cfg.cx_pix + qmul_ref(sxn, cfg.halfw_scaled);
          sy  = cfg.cy_pix + qmul_ref(syn, cfg.halfh_scaled);

          if (sx < 0) begin
            x0 = 0; fx = 0;
          end else begin
            x0s = sx >>> FRAC_BITS;
            if (x0s > (cfg.w - 2)) begin x0 = cfg.w - 2; fx = 255; end
            else begin x0 = int'(x0s); fx = bits_ref(sx, 15, 8); end
          end
          if (sy < 0) begin
            y0 = 0; fy = 0;
          end else begin
            y0s = sy >>> FRAC_BITS;
            if (y0s > (cfg.h - 2)) begin y0 = cfg.h - 2; fy = 255; end
            else begin y0 = int'(y0s); fy = bits_ref(sy, 15, 8); end
          end

          idx_tl = y0 * cfg.w + x0;
          idx_tr = idx_tl + 1;
          idx_bl = idx_tl + cfg.w;
          idx_br = idx_bl + 1;

          w00 = (256 - fx) * (256 - fy);
          w10 = fx * (256 - fy);
          w01 = (256 - fx) * fy;
          w11 = fx * fy;

          acc = longint'(src_r[idx_tl]) * w00 + longint'(src_r[idx_tr]) * w10
              + longint'(src_r[idx_bl]) * w01 + longint'(src_r[idx_br]) * w11 + 32768;
          out_r[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_g[idx_tl]) * w00 + longint'(src_g[idx_tr]) * w10
              + longint'(src_g[idx_bl]) * w01 + longint'(src_g[idx_br]) * w11 + 32768;
          out_g[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_b[idx_tl]) * w00 + longint'(src_b[idx_tr]) * w10
              + longint'(src_b[idx_bl]) * w01 + longint'(src_b[idx_br]) * w11 + 32768;
          out_b[y * cfg.w + x] = 8'(acc >>> 16);
        end
      end
    end
  endtask

  // Generalized counterpart of radial_remap_ref above: additionally
  // supports tangential distortion (p1,p2) and the model_sel hook gate
  // (model_sel_is_radial=0 -> exact identity round trip, k1/k2/k3/p1/p2
  // ignored -- matches coord_gen.sv's ARCHITECTURE HOOK behavior). Used
  // by the new fisheye/panoramic/perspective image-level hook tests to
  // confirm that selecting one of those reserved model IDs makes the
  // whole streaming pipeline reproduce its input, even with nonzero
  // distortion coefficients configured (proving the hook genuinely
  // ignores them, not just that zero coefficients happen to look like
  // identity). Bilinear sampling only (bicubic omitted here -- the hook
  // gate itself is what's under test, not the interpolator, and it's
  // already exhaustively covered by the main 12-scenario matrix).
  // Full-image counterpart of coord_gen_ref: calls it per-pixel (reusing
  // that single already cross-checked implementation rather than
  // duplicating the per-model math again) and bilinear-samples the
  // result. Used both to synthesize fisheye/panoramic/perspective-
  // distorted test images (forward warp) and to compute the golden
  // corrected reference for the image-level correction tests below.
  task automatic full_remap_ref(
    input  remap_cfg_t cfg,
    input  int          model_sel,
    input  longint      k1_q16, input longint k2_q16, input longint k3_q16,
    input  longint      p1_q16, input longint p2_q16,
    input  longint      h11, input longint h12, input longint h13,
    input  longint      h21, input longint h22, input longint h23,
    input  longint      h31, input longint h32,
    input  logic [7:0] src_r[], input logic [7:0] src_g[], input logic [7:0] src_b[],
    output logic [7:0] out_r[], output logic [7:0] out_g[], output logic [7:0] out_b[]
  );
    int x, y, x0, y0, fx, fy;
    longint sx, sy, x0s, y0s;
    int idx_tl, idx_tr, idx_bl, idx_br;
    longint w00, w10, w01, w11, acc;
    begin
      out_r = new[cfg.w * cfg.h];
      out_g = new[cfg.w * cfg.h];
      out_b = new[cfg.w * cfg.h];

      for (y = 0; y < cfg.h; y = y + 1) begin
        for (x = 0; x < cfg.w; x = x + 1) begin
          coord_gen_ref(cfg.cx_pix, cfg.cy_pix, cfg.halfw_scaled, cfg.halfh_scaled,
                         k1_q16, k2_q16, k3_q16, p1_q16, p2_q16, model_sel,
                         h11, h12, h13, h21, h22, h23, h31, h32,
                         x, y, sx, sy);

          if (sx < 0) begin
            x0 = 0; fx = 0;
          end else begin
            x0s = sx >>> FRAC_BITS;
            if (x0s > (cfg.w - 2)) begin x0 = cfg.w - 2; fx = 255; end
            else begin x0 = int'(x0s); fx = bits_ref(sx, 15, 8); end
          end
          if (sy < 0) begin
            y0 = 0; fy = 0;
          end else begin
            y0s = sy >>> FRAC_BITS;
            if (y0s > (cfg.h - 2)) begin y0 = cfg.h - 2; fy = 255; end
            else begin y0 = int'(y0s); fy = bits_ref(sy, 15, 8); end
          end

          idx_tl = y0 * cfg.w + x0;
          idx_tr = idx_tl + 1;
          idx_bl = idx_tl + cfg.w;
          idx_br = idx_bl + 1;

          w00 = (256 - fx) * (256 - fy);
          w10 = fx * (256 - fy);
          w01 = (256 - fx) * fy;
          w11 = fx * fy;

          acc = longint'(src_r[idx_tl]) * w00 + longint'(src_r[idx_tr]) * w10
              + longint'(src_r[idx_bl]) * w01 + longint'(src_r[idx_br]) * w11 + 32768;
          out_r[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_g[idx_tl]) * w00 + longint'(src_g[idx_tr]) * w10
              + longint'(src_g[idx_bl]) * w01 + longint'(src_g[idx_br]) * w11 + 32768;
          out_g[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_b[idx_tl]) * w00 + longint'(src_b[idx_tr]) * w10
              + longint'(src_b[idx_bl]) * w01 + longint'(src_b[idx_br]) * w11 + 32768;
          out_b[y * cfg.w + x] = 8'(acc >>> 16);
        end
      end
    end
  endtask

  task automatic radial_remap_generalized_ref(
    input  remap_cfg_t cfg,
    input  bit          model_sel_is_radial,
    input  longint      k1_q16, input longint k2_q16, input longint k3_q16,
    input  longint      p1_q16, input longint p2_q16,
    input  logic [7:0] src_r[], input logic [7:0] src_g[], input logic [7:0] src_b[],
    output logic [7:0] out_r[], output logic [7:0] out_g[], output logic [7:0] out_b[]
  );
    int x, y, x0, y0, fx, fy;
    longint dx, dy, nx, ny, r2, r4, r6, t1, t2, t3, factor, sxn, syn, sx, sy, x0s, y0s;
    longint tangx, tangy;
    int idx_tl, idx_tr, idx_bl, idx_br;
    longint w00, w10, w01, w11, acc;
    begin
      out_r = new[cfg.w * cfg.h];
      out_g = new[cfg.w * cfg.h];
      out_b = new[cfg.w * cfg.h];

      for (y = 0; y < cfg.h; y = y + 1) begin
        dy = (longint'(y) <<< FRAC_BITS) - cfg.cy_pix;
        ny = qmul_ref(dy, cfg.recip_halfh);
        for (x = 0; x < cfg.w; x = x + 1) begin
          dx = (longint'(x) <<< FRAC_BITS) - cfg.cx_pix;
          nx = qmul_ref(dx, cfg.recip_halfw);

          r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);
          if (model_sel_is_radial) begin
            r4 = qmul_ref(r2, r2);
            r6 = qmul_ref(r4, r2);
            t1 = qmul_ref(k1_q16, r2);
            t2 = qmul_ref(k2_q16, r4);
            t3 = qmul_ref(k3_q16, r6);
            factor = ONE_Q16 + t1 + t2 + t3;
            tangx  = (qmul_ref(p1_q16, qmul_ref(nx, ny)) <<< 1) + qmul_ref(p2_q16, r2 + (qmul_ref(nx, nx) <<< 1));
            tangy  = qmul_ref(p1_q16, r2 + (qmul_ref(ny, ny) <<< 1)) + (qmul_ref(p2_q16, qmul_ref(nx, ny)) <<< 1);
          end else begin
            factor = ONE_Q16;
            tangx  = 0;
            tangy  = 0;
          end

          sxn = qmul_ref(nx, factor) + tangx;
          syn = qmul_ref(ny, factor) + tangy;
          sx  = cfg.cx_pix + qmul_ref(sxn, cfg.halfw_scaled);
          sy  = cfg.cy_pix + qmul_ref(syn, cfg.halfh_scaled);

          if (sx < 0) begin
            x0 = 0; fx = 0;
          end else begin
            x0s = sx >>> FRAC_BITS;
            if (x0s > (cfg.w - 2)) begin x0 = cfg.w - 2; fx = 255; end
            else begin x0 = int'(x0s); fx = bits_ref(sx, 15, 8); end
          end
          if (sy < 0) begin
            y0 = 0; fy = 0;
          end else begin
            y0s = sy >>> FRAC_BITS;
            if (y0s > (cfg.h - 2)) begin y0 = cfg.h - 2; fy = 255; end
            else begin y0 = int'(y0s); fy = bits_ref(sy, 15, 8); end
          end

          idx_tl = y0 * cfg.w + x0;
          idx_tr = idx_tl + 1;
          idx_bl = idx_tl + cfg.w;
          idx_br = idx_bl + 1;

          w00 = (256 - fx) * (256 - fy);
          w10 = fx * (256 - fy);
          w01 = (256 - fx) * fy;
          w11 = fx * fy;

          acc = longint'(src_r[idx_tl]) * w00 + longint'(src_r[idx_tr]) * w10
              + longint'(src_r[idx_bl]) * w01 + longint'(src_r[idx_br]) * w11 + 32768;
          out_r[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_g[idx_tl]) * w00 + longint'(src_g[idx_tr]) * w10
              + longint'(src_g[idx_bl]) * w01 + longint'(src_g[idx_br]) * w11 + 32768;
          out_g[y * cfg.w + x] = 8'(acc >>> 16);

          acc = longint'(src_b[idx_tl]) * w00 + longint'(src_b[idx_tr]) * w10
              + longint'(src_b[idx_bl]) * w01 + longint'(src_b[idx_br]) * w11 + 32768;
          out_b[y * cfg.w + x] = 8'(acc >>> 16);
        end
      end
    end
  endtask

  // Cubic-convolution (Catmull-Rom, a=-0.5) weight, 4 taps at relative
  // offsets -1,0,+1,+2 from the fractional sample point t (Q16.16,
  // 0<=t<65536). Independent re-derivation of the same closed-form
  // polynomial the RTL (bicubic.sv) implements -- written from scratch
  // here, not shared code, per this project's verification philosophy.
  task automatic cubic_weights_ref(
    input  longint t,
    output longint w0, output longint w1, output longint w2, output longint w3
  );
    longint t2, t3;
    longint NEG_HALF, HALF, ONE, ONE_HALF, NEG_ONE_HALF, TWO, TWO_HALF;
    begin
      NEG_HALF = -32'sd32768; HALF = 32'sd32768; ONE = 32'sd65536;
      ONE_HALF = 32'sd98304; NEG_ONE_HALF = -32'sd98304; TWO = 32'sd131072;
      TWO_HALF = 32'sd163840;
      t2 = qmul_ref(t, t);
      t3 = qmul_ref(t2, t);
      w0 = qmul_ref(NEG_HALF, t3) + t2 - qmul_ref(HALF, t);
      w1 = qmul_ref(ONE_HALF, t3) - qmul_ref(TWO_HALF, t2) + ONE;
      w2 = qmul_ref(NEG_ONE_HALF, t3) + qmul_ref(TWO, t2) + qmul_ref(HALF, t);
      w3 = qmul_ref(HALF, t3) - qmul_ref(HALF, t2);
    end
  endtask

  // Bicubic counterpart of radial_remap_ref: same coord_gen math, but a
  // 4x4-tap separable Catmull-Rom footprint instead of 2x2 bilinear.
  // Anchor x0=floor(sx) clamped into [1,w-3] (y0 into [1,h-3]) exactly as
  // axis_out_ctrl.sv's bicubic gather FSM does, with t forced to 0 at
  // either clamp boundary.
  task automatic radial_remap_bicubic_ref(
    input  remap_cfg_t cfg,
    input  longint      k1_q16, input longint k2_q16, input longint k3_q16,
    input  logic [7:0] src_r[], input logic [7:0] src_g[], input logic [7:0] src_b[],
    output logic [7:0] out_r[], output logic [7:0] out_g[], output logic [7:0] out_b[]
  );
    int x, y, x0, y0;
    longint dx, dy, nx, ny, r2, r4, r6, t1, t2, t3, factor, sxn, syn, sx, sy, x0s, y0s;
    longint tx, ty;
    longint wx0, wx1, wx2, wx3, wy0, wy1, wy2, wy3;
    longint rowR0,rowR1,rowR2,rowR3, rowG0,rowG1,rowG2,rowG3, rowB0,rowB1,rowB2,rowB3;
    longint finalR, finalG, finalB;
    int xm1, xp0, xp1, xp2, ym1, yp0, yp1, yp2;
    longint acc;
    begin
      out_r = new[cfg.w * cfg.h];
      out_g = new[cfg.w * cfg.h];
      out_b = new[cfg.w * cfg.h];

      for (y = 0; y < cfg.h; y = y + 1) begin
        dy = (longint'(y) <<< FRAC_BITS) - cfg.cy_pix;
        ny = qmul_ref(dy, cfg.recip_halfh);
        for (x = 0; x < cfg.w; x = x + 1) begin
          dx = (longint'(x) <<< FRAC_BITS) - cfg.cx_pix;
          nx = qmul_ref(dx, cfg.recip_halfw);

          r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);
          r4 = qmul_ref(r2, r2);
          r6 = qmul_ref(r4, r2);
          t1 = qmul_ref(k1_q16, r2);
          t2 = qmul_ref(k2_q16, r4);
          t3 = qmul_ref(k3_q16, r6);
          factor = ONE_Q16 + t1 + t2 + t3;

          sxn = qmul_ref(nx, factor);
          syn = qmul_ref(ny, factor);
          sx  = cfg.cx_pix + qmul_ref(sxn, cfg.halfw_scaled);
          sy  = cfg.cy_pix + qmul_ref(syn, cfg.halfh_scaled);

          if (sx < 0) begin
            x0 = 1; tx = 0;
          end else begin
            x0s = sx >>> FRAC_BITS;
            if (x0s < 1)              begin x0 = 1; tx = 0; end
            else if (x0s > cfg.w - 3) begin x0 = cfg.w - 3; tx = 0; end
            else                      begin x0 = int'(x0s); tx = sx & 64'hFFFF; end
          end
          if (sy < 0) begin
            y0 = 1; ty = 0;
          end else begin
            y0s = sy >>> FRAC_BITS;
            if (y0s < 1)              begin y0 = 1; ty = 0; end
            else if (y0s > cfg.h - 3) begin y0 = cfg.h - 3; ty = 0; end
            else                      begin y0 = int'(y0s); ty = sy & 64'hFFFF; end
          end

          cubic_weights_ref(tx, wx0, wx1, wx2, wx3);
          cubic_weights_ref(ty, wy0, wy1, wy2, wy3);

          xm1 = x0-1; xp0 = x0; xp1 = x0+1; xp2 = x0+2;
          ym1 = y0-1; yp0 = y0; yp1 = y0+1; yp2 = y0+2;

          rowR0 = longint'(src_r[ym1*cfg.w+xm1])*wx0 + longint'(src_r[ym1*cfg.w+xp0])*wx1
                + longint'(src_r[ym1*cfg.w+xp1])*wx2 + longint'(src_r[ym1*cfg.w+xp2])*wx3;
          rowR1 = longint'(src_r[yp0*cfg.w+xm1])*wx0 + longint'(src_r[yp0*cfg.w+xp0])*wx1
                + longint'(src_r[yp0*cfg.w+xp1])*wx2 + longint'(src_r[yp0*cfg.w+xp2])*wx3;
          rowR2 = longint'(src_r[yp1*cfg.w+xm1])*wx0 + longint'(src_r[yp1*cfg.w+xp0])*wx1
                + longint'(src_r[yp1*cfg.w+xp1])*wx2 + longint'(src_r[yp1*cfg.w+xp2])*wx3;
          rowR3 = longint'(src_r[yp2*cfg.w+xm1])*wx0 + longint'(src_r[yp2*cfg.w+xp0])*wx1
                + longint'(src_r[yp2*cfg.w+xp1])*wx2 + longint'(src_r[yp2*cfg.w+xp2])*wx3;

          rowG0 = longint'(src_g[ym1*cfg.w+xm1])*wx0 + longint'(src_g[ym1*cfg.w+xp0])*wx1
                + longint'(src_g[ym1*cfg.w+xp1])*wx2 + longint'(src_g[ym1*cfg.w+xp2])*wx3;
          rowG1 = longint'(src_g[yp0*cfg.w+xm1])*wx0 + longint'(src_g[yp0*cfg.w+xp0])*wx1
                + longint'(src_g[yp0*cfg.w+xp1])*wx2 + longint'(src_g[yp0*cfg.w+xp2])*wx3;
          rowG2 = longint'(src_g[yp1*cfg.w+xm1])*wx0 + longint'(src_g[yp1*cfg.w+xp0])*wx1
                + longint'(src_g[yp1*cfg.w+xp1])*wx2 + longint'(src_g[yp1*cfg.w+xp2])*wx3;
          rowG3 = longint'(src_g[yp2*cfg.w+xm1])*wx0 + longint'(src_g[yp2*cfg.w+xp0])*wx1
                + longint'(src_g[yp2*cfg.w+xp1])*wx2 + longint'(src_g[yp2*cfg.w+xp2])*wx3;

          rowB0 = longint'(src_b[ym1*cfg.w+xm1])*wx0 + longint'(src_b[ym1*cfg.w+xp0])*wx1
                + longint'(src_b[ym1*cfg.w+xp1])*wx2 + longint'(src_b[ym1*cfg.w+xp2])*wx3;
          rowB1 = longint'(src_b[yp0*cfg.w+xm1])*wx0 + longint'(src_b[yp0*cfg.w+xp0])*wx1
                + longint'(src_b[yp0*cfg.w+xp1])*wx2 + longint'(src_b[yp0*cfg.w+xp2])*wx3;
          rowB2 = longint'(src_b[yp1*cfg.w+xm1])*wx0 + longint'(src_b[yp1*cfg.w+xp0])*wx1
                + longint'(src_b[yp1*cfg.w+xp1])*wx2 + longint'(src_b[yp1*cfg.w+xp2])*wx3;
          rowB3 = longint'(src_b[yp2*cfg.w+xm1])*wx0 + longint'(src_b[yp2*cfg.w+xp0])*wx1
                + longint'(src_b[yp2*cfg.w+xp1])*wx2 + longint'(src_b[yp2*cfg.w+xp2])*wx3;

          finalR = qmul_ref(rowR0,wy0) + qmul_ref(rowR1,wy1) + qmul_ref(rowR2,wy2) + qmul_ref(rowR3,wy3);
          finalG = qmul_ref(rowG0,wy0) + qmul_ref(rowG1,wy1) + qmul_ref(rowG2,wy2) + qmul_ref(rowG3,wy3);
          finalB = qmul_ref(rowB0,wy0) + qmul_ref(rowB1,wy1) + qmul_ref(rowB2,wy2) + qmul_ref(rowB3,wy3);

          acc = finalR + 32768; acc = acc >>> 16;
          out_r[y*cfg.w+x] = (acc < 0) ? 8'd0 : (acc > 255) ? 8'd255 : 8'(acc);
          acc = finalG + 32768; acc = acc >>> 16;
          out_g[y*cfg.w+x] = (acc < 0) ? 8'd0 : (acc > 255) ? 8'd255 : 8'(acc);
          acc = finalB + 32768; acc = acc >>> 16;
          out_b[y*cfg.w+x] = (acc < 0) ? 8'd0 : (acc > 255) ? 8'd255 : 8'(acc);
        end
      end
    end
  endtask

  // Independent reference for coord_gen.sv's per-pixel math, INCLUDING
  // the camera-calibration-style direct fx/fy/cx/cy parameterization,
  // tangential ("plumb bob") distortion, and the model_sel hook gate.
  // model_sel_is_radial=0 exercises the ARCHITECTURE HOOK path: expected
  // behavior is an exact normalize/denormalize round trip with NO radial
  // or tangential contribution (k1/k2/k3/p1/p2 ignored), matching what
  // coord_gen.sv does for any non-MODEL_RADIAL model_sel value.
  // Extended: now also implements the REAL fisheye/panoramic/perspective
  // math (coord_gen.sv's "slow path" -- a per-pixel-reciprocal division
  // model for fisheye/panoramic, a homography for perspective), not just
  // the identity-hook behavior AFFINE/SCALING still use. model_sel is
  // distortion_model_e's raw encoding: 0=RADIAL,1=FISHEYE,2=AFFINE,
  // 3=PERSPECTIVE,4=SCALING,5=PANORAMIC (matching distortion_model_pkg.sv).
  task automatic coord_gen_ref(
    input  longint cx_pix, input longint cy_pix,
    input  longint fx_pix, input longint fy_pix,
    input  longint k1, input longint k2, input longint k3,
    input  longint p1, input longint p2,
    input  int     model_sel,
    input  longint h11, input longint h12, input longint h13,
    input  longint h21, input longint h22, input longint h23,
    input  longint h31, input longint h32,
    input  int     x, input int y,
    output longint sx, output longint sy
  );
    longint dx, dy, nx, ny, recip_fx, recip_fy;
    longint r2, r4, r6, t1, t2, t3, factor;
    longint tangx, tangy, sxn, syn;
    longint denom_raw, denom_safe, recip_denom;
    longint xq, yq, num_x, num_y;
    begin
      recip_fx = recip_ref(fx_pix);
      recip_fy = recip_ref(fy_pix);
      dx = (longint'(x) <<< FRAC_BITS) - cx_pix;
      dy = (longint'(y) <<< FRAC_BITS) - cy_pix;
      nx = qmul_ref(dx, recip_fx);
      ny = qmul_ref(dy, recip_fy);
      r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);

      if (model_sel == 0) begin  // MODEL_RADIAL
        r4 = qmul_ref(r2, r2);
        r6 = qmul_ref(r4, r2);
        t1 = qmul_ref(k1, r2);
        t2 = qmul_ref(k2, r4);
        t3 = qmul_ref(k3, r6);
        factor = ONE_Q16 + t1 + t2 + t3;
        tangx = (qmul_ref(p1, qmul_ref(nx, ny)) <<< 1) + qmul_ref(p2, r2 + (qmul_ref(nx, nx) <<< 1));
        tangy = qmul_ref(p1, r2 + (qmul_ref(ny, ny) <<< 1)) + (qmul_ref(p2, qmul_ref(nx, ny)) <<< 1);
        sxn = qmul_ref(nx, factor) + tangx;
        syn = qmul_ref(ny, factor) + tangy;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end else if (model_sel == 1) begin  // MODEL_FISHEYE (division model)
        r4 = qmul_ref(r2, r2);
        denom_raw = ONE_Q16 + qmul_ref(k1, r2) + qmul_ref(k2, r4);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(qmul_ref(ny, recip_denom), fy_pix);
      end else if (model_sel == 5) begin  // MODEL_PANORAMIC (division model, x only)
        denom_raw = ONE_Q16 + qmul_ref(k1, qmul_ref(nx, nx));
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(ny, fy_pix);
      end else if (model_sel == 3) begin  // MODEL_PERSPECTIVE (homography)
        xq = longint'(x) <<< FRAC_BITS;
        yq = longint'(y) <<< FRAC_BITS;
        denom_raw = ONE_Q16 + qmul_ref(h31, xq) + qmul_ref(h32, yq);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        num_x = qmul_ref(h11, xq) + qmul_ref(h12, yq) + h13;
        num_y = qmul_ref(h21, xq) + qmul_ref(h22, yq) + h23;
        sx = qmul_ref(num_x, recip_denom);
        sy = qmul_ref(num_y, recip_denom);
      end else begin  // MODEL_AFFINE / MODEL_SCALING: reserved hooks, identity
        sxn = nx;
        syn = ny;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end
    end
  endtask


  // its radius map, then fits correction coefficients of the same
  // polynomial form via closed-form 3x3 least squares -- the same
  // approach a real lens-correction coefficient set would be calibrated
  // with. Uses `real` arithmetic (this is a one-shot, testbench-only
  // numerical fit, not part of the per-pixel hardware datapath).
  task automatic fit_correction_coeffs(
    input  real kd1, input real kd2, input real kd3,
    output real kc1, output real kc2, output real kc3
  );
    int n, i;
    real r_max, ru, rd, target;
    real f2, f4, f6;
    // normal-equation accumulators for A^T A (3x3, symmetric) and A^T b (3x1)
    real s22, s24, s26, s44, s46, s66, b2, b4, b6;
    real det, i22,i24,i26,i44,i46,i66; // not used directly; solved via Cramer's rule below
    real m[3][3], rhs[3];
    real d0, d1, d2, d3;
    begin
      n = 400; r_max = 1.6;
      s22=0; s24=0; s26=0; s44=0; s46=0; s66=0; b2=0; b4=0; b6=0;
      for (i = 1; i <= n; i = i + 1) begin
        ru = r_max * real'(i) / real'(n);
        rd = ru * (1.0 + kd1*ru*ru + kd2*ru*ru*ru*ru + kd3*ru*ru*ru*ru*ru*ru);
        if (rd > 1.0e-6) begin
          target = ru/rd - 1.0;
          f2 = rd*rd; f4 = f2*f2; f6 = f4*f2;
          s22 += f2*f2; s24 += f2*f4; s26 += f2*f6;
          s44 += f4*f4; s46 += f4*f6; s66 += f6*f6;
          b2  += f2*target; b4 += f4*target; b6 += f6*target;
        end
      end
      // symmetric 3x3 system:
      // [s22 s24 s26][kc1]   [b2]
      // [s24 s44 s46][kc2] = [b4]
      // [s26 s46 s66][kc3]   [b6]
      m[0][0]=s22; m[0][1]=s24; m[0][2]=s26; rhs[0]=b2;
      m[1][0]=s24; m[1][1]=s44; m[1][2]=s46; rhs[1]=b4;
      m[2][0]=s26; m[2][1]=s46; m[2][2]=s66; rhs[2]=b6;

      det = m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
          - m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
          + m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);

      d1 = rhs[0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
         - m[0][1]*(rhs[1]*m[2][2]-m[1][2]*rhs[2])
         + m[0][2]*(rhs[1]*m[2][1]-m[1][1]*rhs[2]);

      d2 = m[0][0]*(rhs[1]*m[2][2]-m[1][2]*rhs[2])
         - rhs[0]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
         + m[0][2]*(m[1][0]*rhs[2]-rhs[1]*m[2][0]);

      d3 = m[0][0]*(m[1][1]*rhs[2]-rhs[1]*m[2][1])
         - m[0][1]*(m[1][0]*rhs[2]-rhs[1]*m[2][0])
         + rhs[0]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);

      kc1 = d1/det; kc2 = d2/det; kc3 = d3/det;
    end
  endtask

  task automatic generate_synthetic_chart(
    input  int w, input int h,
    output logic [7:0] img_r[], output logic [7:0] img_g[], output logic [7:0] img_b[]
  );
    int x, y, cx, cy, ring, step, dxp, dyp;
    real r;
    begin
      img_r = new[w*h]; img_g = new[w*h]; img_b = new[w*h];
      step = (w/16 > 6) ? w/16 : 6;
      cx = w/2; cy = h/2;
      for (y = 0; y < h; y = y+1) begin
        for (x = 0; x < w; x = x+1) begin
          img_r[y*w+x] = 250; img_g[y*w+x] = 250; img_b[y*w+x] = 250;
        end
      end
      for (x = 0; x < w; x = x + step)
        for (y = 0; y < h; y = y+1) begin img_r[y*w+x]=40; img_g[y*w+x]=40; img_b[y*w+x]=40; end
      for (y = 0; y < h; y = y + step)
        for (x = 0; x < w; x = x+1) begin img_r[y*w+x]=40; img_g[y*w+x]=40; img_b[y*w+x]=40; end
      for (ring = step; ring < (w<h?w:h)*0.6; ring = ring + step) begin
        for (y = 0; y < h; y = y+1) begin
          for (x = 0; x < w; x = x+1) begin
            dxp = x-cx; dyp = y-cy;
            r = $sqrt(real'(dxp*dxp+dyp*dyp));
            if (r > real'(ring)-1.0 && r < real'(ring)+1.0) begin
              img_r[y*w+x] = (60 + (ring/step)*40) % 256;
              img_g[y*w+x] = (180 - (ring/step)*20 + 256) % 256;
              img_b[y*w+x] = (20 + (ring/step)*30) % 256;
            end
          end
        end
      end
    end
  endtask

  // Closed-form 3x3 matrix inverse (cofactor/adjugate method), for
  // finding the CORRECTING homography given the (known, since we chose
  // it to synthesize the test image) forward-distorting one -- an exact
  // inverse, unlike the approximate/fitted corrections the radial and
  // division models below use, because a homography's exact inverse is
  // both well-defined and easy to compute in closed form. `real`
  // arithmetic (a one-shot testbench-side computation, not part of the
  // per-pixel hardware datapath).
  task automatic invert_homography(
    input  real h11, input real h12, input real h13,
    input  real h21, input real h22, input real h23,
    input  real h31, input real h32,
    output real i11, output real i12, output real i13,
    output real i21, output real i22, output real i23,
    output real i31, output real i32
  );
    real h33, det;
    real a[3][3], adj[3][3];
    int r, c;
    begin
      h33 = 1.0;
      a[0][0]=h11; a[0][1]=h12; a[0][2]=h13;
      a[1][0]=h21; a[1][1]=h22; a[1][2]=h23;
      a[2][0]=h31; a[2][1]=h32; a[2][2]=h33;

      det = a[0][0]*(a[1][1]*a[2][2]-a[1][2]*a[2][1])
          - a[0][1]*(a[1][0]*a[2][2]-a[1][2]*a[2][0])
          + a[0][2]*(a[1][0]*a[2][1]-a[1][1]*a[2][0]);
      if (det == 0.0) det = 1.0e-9; // degenerate guard (shouldn't happen for our test matrices)

      adj[0][0] =  (a[1][1]*a[2][2]-a[1][2]*a[2][1]);
      adj[0][1] = -(a[0][1]*a[2][2]-a[0][2]*a[2][1]);
      adj[0][2] =  (a[0][1]*a[1][2]-a[0][2]*a[1][1]);
      adj[1][0] = -(a[1][0]*a[2][2]-a[1][2]*a[2][0]);
      adj[1][1] =  (a[0][0]*a[2][2]-a[0][2]*a[2][0]);
      adj[1][2] = -(a[0][0]*a[1][2]-a[0][2]*a[1][0]);
      adj[2][0] =  (a[1][0]*a[2][1]-a[1][1]*a[2][0]);
      adj[2][1] = -(a[0][0]*a[2][1]-a[0][1]*a[2][0]);
      adj[2][2] =  (a[0][0]*a[1][1]-a[0][1]*a[1][0]);

      // Normalize so the inverse's own [2][2] element is 1.0 (matching
      // this design's h33=1 convention -- a homography and any scalar
      // multiple of it represent the same projective transform).
      i11 = adj[0][0]/det/(adj[2][2]/det); i12 = adj[0][1]/det/(adj[2][2]/det); i13 = adj[0][2]/det/(adj[2][2]/det);
      i21 = adj[1][0]/det/(adj[2][2]/det); i22 = adj[1][1]/det/(adj[2][2]/det); i23 = adj[1][2]/det/(adj[2][2]/det);
      i31 = adj[2][0]/det/(adj[2][2]/det); i32 = adj[2][1]/det/(adj[2][2]/det);
    end
  endtask

  // Simple grid search for the division-model (fisheye/panoramic)
  // correction coefficient(s): tries a spread of candidate kc1 (and, for
  // fisheye, kc2) values, re-runs full_remap_ref at reduced resolution
  // for speed, and keeps whichever minimizes MAE against the original.
  // Not a closed-form fit (the division model isn't linear in its
  // coefficients the way the radial polynomial's least-squares fit is)
  // -- but the same underlying goal: find coefficients that measurably
  // undo the synthesized distortion, exactly the standard this project's
  // barrel/pincushion tests are already held to.
  task automatic fit_division_model_coeffs(
    input  remap_cfg_t cfg, input int model_sel,
    input  logic [7:0] warp_r[], input logic [7:0] warp_g[], input logic [7:0] warp_b[],
    input  logic [7:0] orig_r[], input logic [7:0] orig_g[], input logic [7:0] orig_b[],
    output longint      best_kc1_q16, output longint best_kc2_q16
  );
    real   kc1_candidates[7];
    real   kc2_candidates[3];
    real   best_mae, mae;
    longint kc1q, kc2q, acc;
    logic [7:0] trial_r[], trial_g[], trial_b[];
    int i, j, n, d;
    begin
      kc1_candidates[0] = 0.05; kc1_candidates[1] = 0.10; kc1_candidates[2] = 0.15;
      kc1_candidates[3] = 0.20; kc1_candidates[4] = 0.25; kc1_candidates[5] = 0.30;
      kc1_candidates[6] = 0.35;
      kc2_candidates[0] = 0.0; kc2_candidates[1] = -0.02; kc2_candidates[2] = 0.02;
      best_mae = 1.0e18;
      best_kc1_q16 = 0; best_kc2_q16 = 0;

      for (i = 0; i < 7; i = i + 1) begin
        for (j = 0; j < 3; j = j + 1) begin
          kc1q = longint'($rtoi(kc1_candidates[i] * 65536.0));
          kc2q = (model_sel == 1) ? longint'($rtoi(kc2_candidates[j] * 65536.0)) : 0;
          full_remap_ref(cfg, model_sel, kc1q, kc2q, 0, 0, 0,
                          0,0,0, 0,0,0, 0,0,
                          warp_r, warp_g, warp_b, trial_r, trial_g, trial_b);
          acc = 0; n = cfg.w * cfg.h;
          for (int p = 0; p < n; p = p + 1) begin
            d = int'(trial_r[p]) - int'(orig_r[p]); if (d<0) d=-d; acc += d;
            d = int'(trial_g[p]) - int'(orig_g[p]); if (d<0) d=-d; acc += d;
            d = int'(trial_b[p]) - int'(orig_b[p]); if (d<0) d=-d; acc += d;
          end
          mae = real'(acc) / real'(n*3);
          if (mae < best_mae) begin
            best_mae = mae;
            best_kc1_q16 = kc1q;
            best_kc2_q16 = kc2q;
          end
          if (model_sel != 1) j = 3; // panoramic has no k2 -- skip inner loop
        end
      end
    end
  endtask

endpackage
