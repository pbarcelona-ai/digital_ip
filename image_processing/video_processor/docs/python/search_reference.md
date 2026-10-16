<!-- Industry reference check of search.py: copied into docs/python/search_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - search.py (2026-10-16)
// Sources:
//   [1] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. object_tracker WIN_X / WIN_Y inclusive, [15:0] first, [31:16] last.
// Comparison with this program (section 6):
//   Matches the object_tracker window registers.
// Result: in line with the reference; no TODO.
```
