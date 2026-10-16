<!-- Industry reference check of spi_flash_ctrl: copied into docs/spi_flash_ctrl_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - spi_flash_ctrl (2026-10-16)
// Sources:
//   [1] Winbond, "W25Q128JV 3V 128M-bit Serial Flash Memory" datasheet Rev. M (2024),
//   https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7161/256_W25Q128JV.pdf - 8.1
//   instruction set (9Fh, 03h, 0Bh, 06h, 02h, 20h, D8h, C7h, 05h), SPI modes 0 and 3
//   [2] Motorola / Freescale, "SPI Block Guide V04.01", S12SPIV4/D (2004), https://web.pa.msu.e
//   du/people/edmunds/Disco_Kraken/SPI_Documents/motorola_freescale_nxp_spi_manual_2000.pdf -
//   CPOL / CPHA
// Published algorithm / equations:
//   W25Q128JV standard SPI: mode 0 or 3, command byte then 24-bit address (MSB first), 03h read
//   (no dummy, up to 50 MHz), 0Bh fast read (8 dummy clocks), 06h write enable before 02h page
//   program (<= 256 bytes, within one page) / 20h, D8h, C7h erase, 05h status register 1 (BUSY
//   = bit 0), 9Fh JEDEC ID; /CS must rise after a whole byte for program / erase to start.
// Comparison with this IP (section 6):
//   Matches: generic command sequencer (opcode, optional 3-byte address, dummy bytes, read or
//   write data) covers all listed commands, mode 0, MSB first, cs_n framing, BUSY polling left
//   to software. sclk stops between bytes while the stream waits (allowed: SPI flash is fully
//   static).
// Result: in line with the reference; no TODO.
```
