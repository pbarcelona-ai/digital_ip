<!-- Industry reference check of ext_frame_buffer: copied into docs/ext_frame_buffer_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - ext_frame_buffer (2026-10-16)
// Sources:
//   [1] Micron, "256Mb SDRAM" MT48LC16M16A2 datasheet,
//   https://www.cs.columbia.edu/~sedwards/classes/2006/4840/256MSDRAM_E.pdf (power-up 100 us,
//   PRECHARGE ALL, >= 2 AUTO REFRESH, LOAD MODE REGISTER; tRP / tRCD 15-20 ns, tRAS >= 37-44
//   ns, tRC 60-66 ns, 8192 refreshes / 64 ms = 7.8 us); JEDEC JESD21-C
// Published algorithm / equations:
//   SDR SDRAM: after power-up wait >= 100 us with clock running, PRECHARGE ALL, >= 2 AUTO
//   REFRESH, LOAD MODE REGISTER (CL, burst); ACTIVE -> tRCD -> READ / WRITE, read data CL
//   clocks later; tRAS before PRECHARGE, tRP after; 8192 AUTO REFRESH per 64 ms (one per 7.8
//   us).
// Comparison with this IP (section 6):
//   Matches at 100 MHz with the defaults: INIT_WAIT 20000 clocks = 200 us >= 100 us, tRP / tRCD
//   2 clocks = 20 ns >= 15-20 ns, tRAS 5 = 50 ns >= 44 ns, tRFC 7 = 70 ns >= 66 ns, refresh
//   every 780 clocks = 7.8 us, CL = 2 (valid up to 133 MHz for -7E parts). The timing
//   parameters are clock-frequency dependent; the header should state the clock they assume.
// TODO(REF-EXT_FRAME_BUFFER-1) [LOW] Clock assumption. Prompt: in
//   image_processing/vision_system/ip/ext_frame_buffer/src/ext_frame_buffer.sv, add a CLK_MHZ
//   parameter (default 100) and derive INIT_WAIT_CYCLES, T_*_CYCLES and REFRESH_INTERVAL_CYCLES
//   from nanosecond values of the Micron MT48LC16M16A2 -7E datasheet (rounded up), with a
//   generate-time $error when CL = 2 is used above 133 MHz; document the assumed device.
```
