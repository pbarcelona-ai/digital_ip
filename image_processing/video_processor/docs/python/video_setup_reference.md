<!-- Industry reference check of video_setup.py: copied into docs/python/video_setup_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_setup.py (2026-10-16)
// Sources:
//   [1] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
//   [2] CTA-861-H, "A DTV Profile for Uncompressed High Speed Digital Interfaces" (2021),
//   section 4 video formats and waveform timings (e.g. VIC 4 1280x720p60: H 1280/110/40/220, V
//   720/5/5/20, +/+ sync); VIC table in libdisplay-info
//   https://gitlab.freedesktop.org/emersion/libdisplay-info
//   [3] OpenCV, Geometric Image Transformations / cv::resize (INTER_LINEAR, half-pixel centres:
//   src = (dst + 0.5) * scale - 0.5, imgproc/src/resize.cpp),
//   https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. Display timing per CTA-861 (active, front porch, sync, back porch);
//   scaler offsets for pixel-centre alignment OFFS = STEP / 2 - 0.5.
// Comparison with this program (section 6):
//   Matches: frame size written to every block, timing registers written in the CTA-861 order,
//   camera stopped while programming. Uses the VP_HACT + 4 k addressing (see video_regs TODO).
// Result: in line with the reference; no TODO.
```
