<!-- Industry reference check of lvds_serializer: copied into docs/lvds_serializer_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - lvds_serializer (2026-10-16)
// Sources:
//   [1] Linux, "LVDS data mapping" device-tree binding (jeida-18 / jeida-24 / vesa-24 slot
//   tables, after JEIDA-59-1999, National Semiconductor OpenLDI 0.95 and the VESA notebook
//   panel standard), https://www.kernel.org/doc/Documentation/devicetree/bindings/display/lvds-
//   data-mapping.yaml; TI SNLA014 https://www.ti.com/lit/pdf/snla014
// Published algorithm / equations:
//   FPD-Link / OpenLDI: each lane carries a 7-bit word per pixel clock (single link), slot 0
//   first; the clock lane carries 1100011 (high for 4 bit times, low for 3).
// Comparison with this IP (section 6):
//   Matches: 7:1 serialisation, bit 6 (slot 0) first, clock word 1100011, dual-link at half
//   rate.
// Result: in line with the reference; no TODO.
```
