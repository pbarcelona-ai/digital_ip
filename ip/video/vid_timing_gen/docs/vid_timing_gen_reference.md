<!-- Industry reference check of vid_timing_gen: copied into docs/vid_timing_gen_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - vid_timing_gen (2026-10-16)
// Sources:
//   [1] CTA-861-H, "A DTV Profile for Uncompressed High Speed Digital Interfaces" (2021),
//   section 4 video formats and waveform timings (e.g. VIC 4 1280x720p60: H 1280/110/40/220, V
//   720/5/5/20, +/+ sync); VIC table in libdisplay-info
//   https://gitlab.freedesktop.org/emersion/libdisplay-info
// Published algorithm / equations:
//   CTA-861 / VESA progressive timing: line = active + front porch + sync + back porch, frame
//   likewise in lines; vsync changes coincident with the leading edge of hsync; sync polarity
//   per format (+/+ for 720p / 1080p).
// Comparison with this IP (section 6):
//   Matches: programmable active / front porch / sync / back porch, vsync on the hsync leading
//   edge, polarities. Genlock by stretching the vertical back porch is an extension (the timing
//   stays legal for sinks that accept a variable VTOTAL, e.g. VRR / most monitors; CTA-861
//   fixed-rate sinks may not).
// TODO(REF-VID_TIMING_GEN-1) [LOW] Genlock and fixed-rate sinks. Prompt: in
//   ip/video/vid_timing_gen/src/vid_timing_gen.sv header, note that lock_en_i changes VTOTAL
//   frame by frame (up to lock_max_i lines), which CTA-861 fixed-rate sinks may reject, and
//   recommend lock_en_i = 0 (or a small lock_max_i) for such displays.
```
