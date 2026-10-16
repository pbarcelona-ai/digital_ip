<!-- Industry reference check of overlay.py: copied into docs/python/overlay_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - overlay.py (2026-10-16)
// Sources:
//   [1] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
//   [2] T. Porter, T. Duff, "Compositing Digital Images", SIGGRAPH 1984,
//   https://graphics.pixar.com/library/Compositing (over: c = a cA + (1 - a) cB)
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. symbol_overlay objects / texts, COMMIT applies at the next frame
//   start.
// Comparison with this program (section 6):
//   Matches: registers written, then COMMIT; shapes / dashes per the symbol_overlay map.
// Result: in line with the reference; no TODO.
```
