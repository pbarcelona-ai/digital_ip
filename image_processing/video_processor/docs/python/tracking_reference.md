<!-- Industry reference check of tracking.py: copied into docs/python/tracking_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - tracking.py (2026-10-16)
// Sources:
//   [1] P. R. Kalata, "The Tracking Index: A Generalized Parameter for alpha-beta and alpha-
//   beta-gamma Target Trackers", IEEE Trans. AES 20(2):174-182, 1984; summary
//   https://en.wikipedia.org/wiki/Alpha_beta_filter (x_p = x + v T; r = z - x_p; x += alpha r;
//   v += beta r / T)
//   [2] I. Haritaoglu, D. Harwood, L. S. Davis, "W4: Real-time surveillance of people and their
//   activities", IEEE PAMI 22(8), 2000, doi:10.1109/34.868683 (background as per-pixel minimum
//   / maximum intensity, foreground outside it)
//   [3] K. Ratakonda, "Real-time digital video stabilization for multi-media applications",
//   ISCAS 1998 vol. 4 pp. 69-72 (row / column integral projections, 1-D shift search by minimum
//   SAD)
//   [4] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. Detector / feature set-up per object_tracker and feature_detect.
// Comparison with this program (section 6):
//   Matches: per-class detector set-up, feature_detect motion / edge settings, sequence
//   handling.
// Result: in line with the reference; no TODO.
```
