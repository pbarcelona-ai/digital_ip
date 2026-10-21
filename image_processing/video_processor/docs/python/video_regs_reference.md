<!-- Industry reference check of video_regs.py: copied into docs/python/video_regs_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_regs.py (2026-10-16)
// Sources:
//   [1] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
//   [2] ip/cpu/py_core/tools/pyc.py header (supported Python subset) and
//   ip/cpu/py_core/docs/py_core_prompt.md
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. Base addresses come from video_processor_map_pkg.sv (shared with the
//   RTL decoders).
// Comparison with this program (section 6):
//   Every offset checked against the JSON maps (69 constants): all addresses are correct.
//   Differs: the offsets are hand-written numbers (only the bases come from the SV package),
//   and some names differ from the register map: VS_CX / VS_CY are CENTER_X / CENTER_Y (0x2C /
//   0x30), while vision_system's CX / CY are the pinhole intrinsics at 0x4C / 0x50; VS_WIDTH /
//   VS_HEIGHT are IMG_WIDTH / IMG_HEIGHT; VP_HACT is H_ACTIVE (the other timing registers are
//   reached as VP_HACT + 4 k).
// TODO(REF-VIDEO_REGS-1) [MEDIUM] Offsets from the register maps. Prompt: make
//   ip/scripts/regmap_gen.py also write src/include/<ip>_regs_pkg.sv with one 'localparam int
//   <PREFIX>_<REG> = 'h<offset>;' per register (and <REG>_<FIELD>_LSB / _MASK per bit field),
//   import those packages in sw/video_regs.py with 'from <ip>_regs_pkg import *' (pyc.py reads
//   SV packages), delete the hand-written offsets, rename VS_CX / VS_CY to the map's CENTER_X /
//   CENTER_Y and use H_FP / H_SYNC / ... instead of VP_HACT + 4 k; rebuild the firmware and
//   rerun the video_processor simulation.
//   DEFERRED (2026-10-19): generating the <ip>_regs_pkg.sv packages is SystemVerilog work, on hold
//   while the design is baselined on the Python models (docs/pending_sv_changes.md); the offsets of
//   the registers added in the Python baseline (sky profile, skin table, display filter) follow the
//   JSON maps and were checked by hand. Resolve with the SV update.
```
