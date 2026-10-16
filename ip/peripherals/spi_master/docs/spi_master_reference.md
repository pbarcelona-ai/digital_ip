<!-- Industry reference check of spi_master: copied into docs/spi_master_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - spi_master (2026-10-16)
// Sources:
//   [1] Motorola / Freescale, "SPI Block Guide V04.01", S12SPIV4/D (2004), https://web.pa.msu.e
//   du/people/edmunds/Disco_Kraken/SPI_Documents/motorola_freescale_nxp_spi_manual_2000.pdf -
//   CPOL / CPHA
// Published algorithm / equations:
//   Motorola SPI: CPOL = SCK idle level; CPHA = 0 samples on the first (leading) edge with data
//   set up before it, CPHA = 1 shifts on the leading edge and samples on the trailing edge; MSB
//   first by default, LSBFE optional; SS low for the transfer.
// Comparison with this IP (section 6):
//   Matches: CPOL / CPHA (all four modes), LSB-first option, programmable word length, chip-
//   select burst framed by tlast, MISO double registered (requires DIV >= 2).
// Result: in line with the reference; no TODO.
```
