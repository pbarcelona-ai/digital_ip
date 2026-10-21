<!-- Industry reference check of coord_gen: copied into docs/coord_gen_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - coord_gen (2026-10-16)
// Sources:
//   [1] OpenCV, Camera Calibration and 3D Reconstruction (calib3d): x'' = x'(1 + k1 r^2 + k2
//   r^4 + k3 r^6) + 2 p1 x'y' + p2 (r^2 + 2x'^2), y'' = y'(...) + p1 (r^2 + 2y'^2) + 2 p2 x'y',
//   u = fx x'' + cx, https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html; fisheye: theta =
//   atan(r), theta_d = theta (1 + k1 theta^2 + k2 theta^4 + k3 theta^6 + k4 theta^8),
//   https://docs.opencv.org/4.x/db/d58/group__calib3d__fisheye.html
//   [2] A. W. Fitzgibbon, "Simultaneous linear estimation of multiple view geometry and lens
//   distortion", CVPR 2001, doi:10.1109/CVPR.2001.990465 (division model r_u = r_d / (1 + k
//   r_d^2))
//   [3] R. Hartley, A. Zisserman, "Multiple View Geometry in Computer Vision", 2nd ed.,
//   Cambridge 2004, ch. 2 / 4 (planar homography x' = H x, h33 = 1 normalisation)
// Published algorithm / equations:
//   OpenCV plumb-bob model: x' = (u - cx) / fx, r^2 = x'^2 + y'^2, x'' = x'(1 + k1 r^2 + k2 r^4
//   + k3 r^6) + 2 p1 x'y' + p2 (r^2 + 2x'^2), y'' = y'(...) + p1 (r^2 + 2y'^2) + 2 p2 x'y',
//   u_src = fx x'' + cx. Fisheye (OpenCV): theta = atan(r), theta_d = theta(1 + k1 theta^2 + k2
//   theta^4 + k3 theta^6 + k4 theta^8). Division model (Fitzgibbon 2001): r_u = r_d / (1 + k
//   r_d^2). Homography (Hartley & Zisserman): x' = (h11 x + h12 y + h13) / (h31 x + h32 y + 1).
// Comparison with this IP (section 6):
//   Radial / tangential path matches OpenCV term for term (k1, k2, k3, p1, p2, pinhole
//   normalisation). Perspective matches the h33 = 1 homography. Differs: MODEL_FISHEYE /
//   MODEL_PANORAMIC use the division model, not OpenCV's equidistant theta polynomial, so
//   coefficients from cv::fisheye::calibrate cannot be used directly; MODEL_AFFINE /
//   MODEL_SCALING are reserved hooks (identity).
// RESOLVED(REF-COORD_GEN-1) [MEDIUM] Fisheye model. Resolution: 2026-10-21: the coord_gen.sv
//   header (MODELS) states that MODEL_FISHEYE is Fitzgibbon's division model (CVPR 2001), not the
//   OpenCV (Kannala-Brandt) fisheye model, and that the calibration software fits the division-model
//   k1 / k2 to the measured or Kannala-Brandt mapping by least squares over the frame
//   (tb/image_io.py fit_division_model_coeffs); a Kannala-Brandt model is not added.
// RESOLVED(REF-COORD_GEN-2) [LOW] Reserved models. Resolution: 2026-10-21: documented:
//   MODEL_AFFINE (2), MODEL_SCALING (4) and codes 6 / 7 are reserved and give the pinhole round trip (near
//   identity, not bit exact) (coord_gen.sv header, distortion_model_pkg.sv, the MODEL_SEL description in
//   vision_system_regs.json: software must not select them); the golden model and tb/python check
//   that mapping. The register block keeps them writable (no SLVERR) so the map stays one plain RW
//   field.
```
