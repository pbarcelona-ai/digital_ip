<!-- Industry reference check of vision_system: copied into docs/vision_system_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - vision_system (2026-10-21)
// Sources:
//   [1] OpenCV, Camera Calibration and 3D Reconstruction (calib3d): x'' = x'(1 + k1 r^2 + k2
//   r^4 + k3 r^6) + 2 p1 x'y' + p2 (r^2 + 2x'^2), y'' = y'(...) + p1 (r^2 + 2y'^2) + 2 p2 x'y',
//   u = fx x'' + cx, https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html; fisheye: theta =
//   atan(r), theta_d = theta (1 + k1 theta^2 + k2 theta^4 + k3 theta^6 + k4 theta^8),
//   https://docs.opencv.org/4.x/db/d58/group__calib3d__fisheye.html
//   [2] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
//   [3] Arm, "AMBA 4 AXI4-Stream Protocol Specification", ARM IHI 0051A (2010) / IHI 0051B
//   (2021), https://developer.arm.com/documentation/ihi0051/b - 2.2 handshake, 2.4 TKEEP /
//   TLAST
//   [4] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   Lens-distortion correction by inverse mapping (OpenCV initUndistortRectifyMap + remap): for
//   every output pixel compute the distorted source coordinate and interpolate (bilinear /
//   bicubic).
// Comparison with this IP (section 6):
//   Matches: coord_gen inverse mapping, bilinear / bicubic interpolation (OpenCV remap with
//   BORDER_REPLICATE: every tap clamped into the frame, version 2.0.0), AXI4-Lite control,
//   AXI4-Stream video with SOF / EOL and back-pressure, synchronous resets. The coord_gen,
//   frame_buffer and ext_frame_buffer items are resolved in their own reference checks.
// Result: in line with the reference; no TODO.
```
