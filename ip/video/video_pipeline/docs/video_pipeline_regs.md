# video_pipeline register map

Camera to display pipeline registers: control, ISP stages, statistics, display timing, MIPI / LVDS outputs, counters.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "VPIP" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x14 | CTRL | RW | 0x00000000 | [0] output enable [1] HDMI (0 = DVI) [2] TPG [3] genlock [5:4] CFA [6] CSC BT.709 [7] insert point |
| 0x18 | BYPASS | RW | 0x000000C0 | stage bypass: [0] BLC [1] WB [2] DPC [3] demosaic [4] CCM [5] gamma [6] CSC [7] scaler |
| 0x1C | STATUS | RO | 0x00000000 | [0] output locked to the camera |
| 0x20 | CSI | RW | 0x0000002B | [5:0] data type (RAW10) [7:6] virtual channel |
| 0x24 | FRAME_SIZE | RW | 0x00000000 | [15:0] camera width [31:16] height |
| 0x28 | BLC_R | RW | 0x00000000 | black level R |
| 0x2C | BLC_GR | RW | 0x00000000 | black level Gr |
| 0x30 | BLC_GB | RW | 0x00000000 | black level Gb |
| 0x34 | BLC_B | RW | 0x00000000 | black level B |
| 0x38 | WB_R | RW | 0x00000100 | white balance gain R, Q4.8 |
| 0x3C | WB_G | RW | 0x00000100 | white balance gain G, Q4.8 |
| 0x40 | WB_B | RW | 0x00000100 | white balance gain B, Q4.8 |
| 0x44 | DPC_THR | RW | 0x00000040 | defect pixel threshold |
| 0x48 | CCM_C00 | RW | 0x00000400 | colour matrix coefficient, signed Q5.10 |
| 0x4C | CCM_C01 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x50 | CCM_C02 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x54 | CCM_C10 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x58 | CCM_C11 | RW | 0x00000400 | colour matrix coefficient, signed Q5.10 |
| 0x5C | CCM_C12 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x60 | CCM_C20 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x64 | CCM_C21 | RW | 0x00000000 | colour matrix coefficient, signed Q5.10 |
| 0x68 | CCM_C22 | RW | 0x00000400 | colour matrix coefficient, signed Q5.10 |
| 0x6C | CCM_OFF_R | RW | 0x00000000 | colour matrix offset R (signed) |
| 0x70 | CCM_OFF_G | RW | 0x00000000 | colour matrix offset G (signed) |
| 0x74 | CCM_OFF_B | RW | 0x00000000 | colour matrix offset B (signed) |
| 0x78 | GAMMA_ADDR | RW | 0x00000000 | gamma table index for the next GAMMA_DATA write |
| 0x7C | GAMMA_DATA | WO | 0x00000000 | [7:0] writes table[index], the index auto-increments |
| 0x80 | STAT_THR | RW | 0x000003E8 | statistics clip threshold (10 bit) |
| 0x84 | STAT_SUM_R | RO | 0x00000000 | sum of R, last frame (low 32 bits) |
| 0x88 | STAT_SUM_G | RO | 0x00000000 | sum of G, last frame (low 32 bits) |
| 0x8C | STAT_SUM_B | RO | 0x00000000 | sum of B, last frame (low 32 bits) |
| 0x90 | STAT_PIX | RO | 0x00000000 | pixels, last frame |
| 0x94 | STAT_CLIP | RO | 0x00000000 | clipped pixels, last frame |
| 0x98 | STAT_FRAMES | RO | 0x00000000 | frames measured |
| 0x9C | H_ACTIVE | RW | 0x00000000 | display: active pixels per line |
| 0xA0 | H_FP | RW | 0x00000000 | display: horizontal front porch |
| 0xA4 | H_SYNC | RW | 0x00000000 | display: horizontal sync width |
| 0xA8 | H_BP | RW | 0x00000000 | display: horizontal back porch |
| 0xAC | V_ACTIVE | RW | 0x00000000 | display: active lines |
| 0xB0 | V_FP | RW | 0x00000000 | display: vertical front porch |
| 0xB4 | V_SYNC | RW | 0x00000000 | display: vertical sync width |
| 0xB8 | V_BP | RW | 0x00000000 | display: vertical back porch |
| 0xBC | SYNC_POL | RW | 0x00000000 | [0] hsync [1] vsync active high |
| 0xC0 | LOCK_MAX | RW | 0x000003FF | genlock: max extra blanking lines |
| 0xC4 | START_LEVEL | RW | 0x00000010 | pixels buffered before a frame starts |
| 0xC8 | AVI | RW | 0x00000200 | HDMI AVI: [6:0] VIC [9:8] picture aspect [11:10] RGB range |
| 0xCC | CSI_FRAMES | RO | 0x00000000 | camera frames received |
| 0xD0 | ECC_CORR | RO | 0x00000000 | CSI-2 header ECC corrections |
| 0xD4 | ECC_ERR | RO | 0x00000000 | CSI-2 header ECC errors |
| 0xD8 | CRC_ERR | RO | 0x00000000 | CSI-2 payload CRC errors |
| 0xDC | UNDERFLOWS | RO | 0x00000000 | display underflows |
| 0xE0 | DPC_CORR | RO | 0x00000000 | defective pixels corrected |
| 0xE4 | CSI_OVERFLOW | RO | 0x00000000 | CSI overflow events (bridge FIFO full; a burst of lost words counts once) |
| 0xE8 | OUT_CTRL | RW | 0x00000000 | [0] LVDS dual [1] LVDS 18 bpp [2] JEIDA [4] DSI video [5] DSI EoTp [7:6] DSI VC [8] CSI-2 TX [9] YUV422 [11:10] VC |
| 0xEC | DSI_GAPS | RW | 0x0006000A | [15:0] LP clocks after a sync packet, [31:16] after pixels |
| 0xF0 | CSITX_GAP | RW | 0x00000008 | LP clocks between CSI-2 TX packets |
| 0xF4 | DSI_CMD | WO | 0x00000000 | queue a DSI command {[24] long, [23:16] data type, [15:0] data / word count} |
| 0xF8 | DSI_CMD_BYTE | WO | 0x00000000 | [7:0] next payload byte of a long command |
| 0xFC | TX_STATUS | RO | 0x00000000 | [0] DSI command queue busy |
| 0x100 | DSI_DROPS | RO | 0x00000000 | lines DSI could not send in time (dropped, or a burst that ran dry) |
| 0x104 | CSITX_DROPS | RO | 0x00000000 | lines CSI-2 TX could not send in time (dropped, or a burst that ran dry) |
| 0x108 | CSITX_FRAMES | RO | 0x00000000 | frames sent by CSI-2 TX |
| 0x10C | BUILD_CFG | RO | 0x00000000 | interfaces built: [0] CSI-2 RX [1] HDMI [2] LVDS [3] DSI [4] CSI-2 TX [5] scaler [6] insert point |
