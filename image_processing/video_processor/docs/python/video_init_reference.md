<!-- Industry reference check of video_init.py: copied into docs/python/video_init_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_init.py (2026-10-16)
// Sources:
//   [1] ip/cpu/py_core/tools/pyc.py header (supported Python subset) and
//   ip/cpu/py_core/docs/py_core_prompt.md
//   [2] Register maps of the addressed blocks: <ip>/src/include/<ip>_regs.json and section 5/6
//   of <ip>/docs/<ip>_prompt.md (video_pipeline, vision_system, blur_sharpen, frame_counter,
//   object_tracker, feature_detect, symbol_overlay, py_soc peripherals)
//   [3] Texas Instruments, "TL16C550C Asynchronous Communications Element", SLLS177H (2006),
//   https://www.ti.com/product/TL16C550C - baud = f_clk / (16 x divisor), mid-bit sampling
//   [4] NXP, "I2C-bus specification and user manual", UM10204 Rev. 7.0 (2021),
//   https://www.nxp.com/docs/en/user-guide/UM10204.pdf - 3.1 (START / STOP, ACK, arbitration,
//   clock stretching), Table 10 (tLOW / tHIGH)
//   [5] Winbond, "W25Q128JV 3V 128M-bit Serial Flash Memory" datasheet Rev. M (2024),
//   https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7161/256_W25Q128JV.pdf - 8.1
//   instruction set (9Fh, 03h, 0Bh, 06h, 02h, 20h, D8h, C7h, 05h), SPI modes 0 and 3
// Published algorithm / rules:
//   Firmware rules: the pyc.py subset; register offsets, access types and bit fields as in the
//   blocks' register maps. Drivers: UART (16550-style status / data ports), I2C master
//   transfers (address, length, START, poll DONE / NACK per UM10204 semantics), SPI flash READ
//   03h (W25Q128JV).
// Comparison with this program (section 6):
//   Matches: I2C transfers write ADDR / LEN, clear STATUS, then CTRL = EN | START | READ (START
//   is a command bit, consistent with i2c_master's CMD-type CTRL), poll DONE with a bound,
//   check NACK; flash reads use 03h with a 3-byte address. Differs: flash_read waits for F_BUSY
//   in an unbounded loop (every other wait uses the bounded wait_set / wait_clear).
// RESOLVED(REF-VIDEO_INIT-1) [LOW] Bounded flash wait. Resolution: 2026-10-16: flash_read uses
//   wait_clear and returns 0 on a timeout; flash_byte is bounded by TMO.
```
