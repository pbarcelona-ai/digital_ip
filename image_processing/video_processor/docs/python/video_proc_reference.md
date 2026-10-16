<!-- Industry reference check of video_proc.py: copied into docs/python/video_proc_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_proc.py (2026-10-16)
// Sources:
//   [1] ip/cpu/py_core/tools/pyc.py header (supported Python subset) and
//   ip/cpu/py_core/docs/py_core_prompt.md
//   [2] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. Program flow per the video_processor prompt (sections 1-8).
// Comparison with this program (section 6):
//   Matches: interrupt handler registered with irq_handler, sections in the order of the system
//   prompt, every step reported on UART 0. No difference found.
// Result: in line with the reference; no TODO.
```
