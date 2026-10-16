<!-- Industry reference check of events.py: copied into docs/python/events_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - events.py (2026-10-16)
// Sources:
//   [1] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. frame_counter event log: read EVENT / EVENT_TIME, pop with
//   EVENT_POP[0], clear overflow with EVENT_POP[1].
// Comparison with this program (section 6):
//   Matches the frame_counter register map and pop protocol.
// Result: in line with the reference; no TODO.
```
