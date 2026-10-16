<!-- Industry reference check of lvds_tx: copied into docs/lvds_tx_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - lvds_tx (2026-10-16)
// Sources:
//   [1] Linux, "LVDS data mapping" device-tree binding (jeida-18 / jeida-24 / vesa-24 slot
//   tables, after JEIDA-59-1999, National Semiconductor OpenLDI 0.95 and the VESA notebook
//   panel standard), https://www.kernel.org/doc/Documentation/devicetree/bindings/display/lvds-
//   data-mapping.yaml; TI SNLA014 https://www.ti.com/lit/pdf/snla014
// Published algorithm / equations:
//   Linux lvds-data-mapping: vesa-24 DATA0 G0 R5 R4 R3 R2 R1 R0, DATA1 B1 B0 G5 G4 G3 G2 G1,
//   DATA2 CTL2 CTL1 CTL0 B5 B4 B3 B2, DATA3 CTL3 B7 B6 G7 G6 R7 R6; jeida-24 DATA0 G2 R7..R2,
//   DATA1 B3 B2 G7..G3, DATA2 CTL2 CTL1 CTL0 B7..B4, DATA3 CTL3 B1 B0 G1 G0 R1 R0; jeida-18 =
//   lanes 0-2 of vesa-24 with 6-bit components; CTL0 = HS, CTL1 = VS, CTL2 = DE.
// Comparison with this IP (section 6):
//   Matches slot for slot (slot 0 = bit 6, first): VESA, JEIDA and 18 bpp tables, DE / VS / HS
//   in CTL2 / CTL1 / CTL0, lane 3 slot 0 (CTL3) = 0.
// Result: in line with the reference; no TODO.
```
