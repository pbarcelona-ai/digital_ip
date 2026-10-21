<!-- Industry reference check of ddr_mem: copied into docs/ddr_mem_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - ddr_mem (2026-10-21)
// Sources:
//   [1] JEDEC, "DDR4 SDRAM Standard", JESD79-4 (2012-2021), https://www.jedec.org/standards-documents/docs/jesd79-4a
//   - 4.x command truth table (ACT, RD, WR, PRE, PREA, REF), timing parameters tRCD, tRP, tRAS, tRTP, tWR,
//   tWTR, tRRD, tRFC, tREFI (up to 8 refreshes may be postponed)
//   [2] DFI Group, "DDR PHY Interface (DFI) Specification" 5.0 (2018), https://www.ddr-phy.org - command
//   interface (dfi_address, dfi_bank, dfi_ras_n / cas_n / we_n, dfi_cs), write data (dfi_wrdata, _en,
//   _mask, tphy_wrlat), read data (dfi_rddata, _valid, trddata_en, tphy_rdlat)
// Published algorithm / equations:
//   A bank must be activated before RD / WR (tRCD later), stays open until PRE (tRAS after ACT, tWR
//   after the last write data, tRTP after a RD), may be activated again tRP after the PRE; ACTs to
//   different banks tRRD apart; a RD tWTR after write data; REF with every bank precharged, nothing for
//   tRFC; on average one REF per tREFI, at most 8 postponed (9 x tREFI between two REFs).
// Comparison with this IP (section 6):
//   Matches: the command set, every listed timing rule, refresh deadline REF_MAX = 9 x tREFI by
//   default, open-row per bank, byte write masks. Simplifications (deliberate, simulation model of the
//   generic build): one encoded cmd field instead of ras_n / cas_n / we_n / cs_n; write data with the WR
//   command (tphy_wrlat 0) and read data T_CL clocks after RD (the controller's view after the PHY's
//   latencies); one data word per command (the burst folded into DATA_W, a 1:1 DFI frequency ratio);
//   no mode registers, ZQ calibration, ODT or tFAW; the timing violations are reported (err_o) instead of
//   corrupting data.
// Result: in line with the reference; no TODO.
```
