<!-- Industry reference check of dsi_tx: copied into docs/dsi_tx_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - dsi_tx (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Display Serial Interface (DSI)" v1.3: 8.11 video mode
//   (non-burst with sync events: VSS 0x01, HSS 0x21, no HSE / VSE), 8.8 data types (packed
//   pixel stream 24-bit 0x3E R,G,B; DCS short write 0x05 / 0x15, DCS long write 0x39), EoTp 08
//   0F 0F 01; summary TI SNLA356 https://www.ti.com/document-
//   viewer/lit/html/SNLA356/GUID-2F47E337-61D9-405B-8259-99385DB44B8A
// Published algorithm / equations:
//   DSI non-burst video mode with sync events: VSS (0x01) at the start of the vertical sync,
//   HSS (0x21) at every other line start, no HSE / VSE; blanking as LP-11 (BLLP) or blanking
//   packets (0x19); pixel data as packed pixel stream 0x3E (R, G, B); commands as DCS short
//   (0x05 / 0x15) and long (0x39) writes; EoTp optional.
// Comparison with this IP (section 6):
//   Matches: VSS / HSS events, LP blanking, 0x3E with R,G,B, DCS command types, EoTp.
//   Implementation choice: pixel data trails its sync event by one line (the line is buffered),
//   so the panel sees a constant one-line offset - legal because only event timing is conveyed.
// Result: in line with the reference; no TODO.
```
