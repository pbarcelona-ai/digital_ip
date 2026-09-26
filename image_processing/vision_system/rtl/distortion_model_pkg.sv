// ***************
// Filename: distortion_model_pkg.sv
// Author: Paul Barcelona
// Description: Defines distortion_model_e (the MODEL_SEL enum: radial,
// fisheye, affine, perspective, scaling, panoramic) and
// calib_params_t, the single packed struct bundling every
// camera-calibration and distortion coefficient coord_gen
// needs, so new models only require a struct-field addition.
// Date: September 26, 2026
// ***************
// =============================================================================
// distortion_model_pkg.sv
//
// Reusable SystemVerilog structure bundling every per-frame calibration /
// distortion parameter coord_gen (or any future distortion-model pipeline)
// needs, plus the model-selector enum used to pick between them.
//
// Bundling these into ONE packed struct (rather than coord_gen taking a
// dozen individual scalar ports, as it used to) is what makes the pipeline
// reusable: adding a new model's parameters is a struct-field addition,
// not a port-list change propagated through every module that instantiates
// or wires up coord_gen (axis_out_ctrl.sv, barrel_correct_top.sv,
// axi_lite_regs.sv).
//
// FIXED-POINT: every field is Q16.16 (see barrel_pkg.sv) unless noted.
//
// CAMERA CALIBRATION: fx_pix/fy_pix/cx_pix/cy_pix follow the standard
// pinhole camera intrinsic-matrix convention (focal lengths and principal
// point, in pixels) --
//     nx = (x - cx_pix) / fx_pix
//     ny = (y - cy_pix) / fy_pix
// rather than this design's original "fraction-of-width center + single
// edge-crop scale" parameterization (CENTER_X/CENTER_Y/SCALE), of which
// fx_pix/fy_pix/cx_pix/cy_pix are a strict generalization: the original
// parameterization is recovered by setting fx_pix=halfW*scale,
// fy_pix=halfH*scale, cx_pix=CENTER_X*width, cy_pix=CENTER_Y*height (this
// is exactly what axi_lite_regs.sv's CALIB_MODE=0, the default, still
// does -- see its header comment). CALIB_MODE=1 takes fx_pix/fy_pix/
// cx_pix/cy_pix directly from AXI-Lite registers instead.
//
// RADIAL + TANGENTIAL DISTORTION: k1/k2/k3 (radial, r^2/r^4/r^6 terms,
// as before) plus p1/p2 (tangential, the standard OpenCV/"plumb bob"
// camera-calibration terms):
//     x' = x*(1+k1 r^2+k2 r^4+k3 r^6) + 2 p1 x y + p2 (r^2 + 2x^2)
//     y' = y*(1+k1 r^2+k2 r^4+k3 r^6) + p1 (r^2 + 2y^2) + 2 p2 x y
// applied only when model_sel==MODEL_RADIAL.
//
// FISHEYE / PANORAMIC (rational "division model"): rather than the
// trigonometric equidistant fisheye model (r_d=f*atan(r_u/f), which needs
// atan/tan hardware this design does not have -- CORDIC or a LUT would be
// the usual answer, neither implemented here), MODEL_FISHEYE uses
// Fitzgibbon's division model, a well-established polynomial-free-of-trig
// alternative that reuses the SAME k1/k2/r^2/r^4 machinery the radial
// model already computes, just as a DIVISOR instead of a multiplier:
//     denom = 1 + k1*r^2 + k2*r^4
//     nx' = nx / denom ; ny' = ny / denom
// This can represent much more severe distortion than a same-order
// multiplicative polynomial, which is exactly why it's a standard choice
// for wide-angle/fisheye lenses in practice. MODEL_PANORAMIC applies the
// same division-model idea but horizontally only (a documented
// approximation of cylindrical dewarp, not full equirectangular-to-
// rectilinear reprojection, which needs multiple trig calls this design
// doesn't have either):
//     denom = 1 + k1*nx^2  ;  nx' = nx/denom ; ny' = ny (unchanged)
// Both need ONE per-pixel reciprocal (fixed_recip.sv, reused -- see
// coord_gen.sv's "slow path" FSM); this breaks the 1-pixel/clock
// throughput the fast RADIAL path sustains, exactly the same documented
// trade-off bicubic mode already makes for the same underlying reason
// (an iterative divider is far cheaper than a combinational one, but only
// affordable once per pixel, not once per pixel per cycle).
//
// PERSPECTIVE (3x3 homography / keystone correction): operates directly
// on PIXEL coordinates (not the normalized nx/ny the other models use --
// homography conventionally isn't normalized against a focal length),
// with h33 fixed at 1.0 (a homography is only defined up to overall
// scale, so fixing the last element is the standard normalization):
//     denom = h31*x + h32*y + 1
//     sx = (h11*x + h12*y + h13) / denom
//     sy = (h21*x + h22*y + h23) / denom
// Identity: h11=h22=1, everything else 0. Also uses the shared per-pixel
// reciprocal (one divide serves both sx and sy, since they share the same
// denominator).
//
// ARCHITECTURE HOOKS: model_sel selects which distortion model coord_gen
// applies. MODEL_RADIAL, MODEL_FISHEYE, MODEL_PANORAMIC and
// MODEL_PERSPECTIVE are all functionally implemented (see above).
// MODEL_AFFINE and MODEL_SCALING remain reserved, documented extension
// points -- selecting them currently makes coord_gen fall back to an
// exact identity mapping (sx=x, sy=y bit-for-bit, verified by the smoke
// test) rather than silently producing wrong output. See the "Extension
// hooks" section of README.md for what each of those two would need.
// =============================================================================
package distortion_model_pkg;

  typedef enum logic [2:0] {
    MODEL_RADIAL      = 3'd0,   // radial (k1,k2,k3) + tangential (p1,p2) -- IMPLEMENTED
    MODEL_FISHEYE     = 3'd1,   // division-model fisheye correction (k1,k2) -- IMPLEMENTED
    MODEL_AFFINE      = 3'd2,   // general 2x3 affine (rotate/shear/translate) -- HOOK, reserved
    MODEL_PERSPECTIVE = 3'd3,   // 3x3 homography / keystone correction -- IMPLEMENTED
    MODEL_SCALING     = 3'd4,   // arbitrary non-uniform resize/crop -- HOOK, reserved
    MODEL_PANORAMIC   = 3'd5    // division-model horizontal (cylindrical-ish) dewarp -- IMPLEMENTED
  } distortion_model_e;

  typedef struct packed {
    // Camera calibration intrinsics (pinhole model), pixels, Q16.16
    logic signed [31:0] cx_pix;
    logic signed [31:0] cy_pix;
    logic signed [31:0] fx_pix;
    logic signed [31:0] fy_pix;
    logic        [31:0] recip_fx;   // 1/fx_pix, Q16.16 unsigned (precomputed -- avoids a
    logic        [31:0] recip_fy;   // per-pixel divide; see fixed_recip.sv)

    // Radial distortion coefficients (r^2, r^4, r^6 terms). Reused, with
    // a different (divisor rather than multiplier) meaning, by
    // MODEL_FISHEYE (k1,k2) and MODEL_PANORAMIC (k1 only) -- see above.
    logic signed [31:0] k1;
    logic signed [31:0] k2;
    logic signed [31:0] k3;

    // Tangential ("plumb bob") distortion coefficients
    logic signed [31:0] p1;
    logic signed [31:0] p2;

    // MODEL_PERSPECTIVE homography coefficients (h33 implicit = 1.0)
    logic signed [31:0] h11;
    logic signed [31:0] h12;
    logic signed [31:0] h13;
    logic signed [31:0] h21;
    logic signed [31:0] h22;
    logic signed [31:0] h23;
    logic signed [31:0] h31;
    logic signed [31:0] h32;

    // Which model to apply -- see distortion_model_e above
    distortion_model_e  model_sel;
  } calib_params_t;

endpackage
