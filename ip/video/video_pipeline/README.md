# video_pipeline

MIPI CSI-2 camera to HDMI / DVI video pipeline. Version 1.1.0. byte_clk | pix_clk D-PHY -> csi2_rx -> axis_async_bridge -> csi2_raw_unpack -> isp_blc_wb -> isp_dpc -> isp_demosaic -> isp_ccm -> isp_gamma -> isp_csc -> [scaler_bilinear | bypass] -> axis_to_video -> hdmi_tx -> TMDS (HDMI / DVI) -> lvds_tx -> OpenLDI (LVDS panel) -> dsi_tx -> MIPI DSI (panel) -> csi2_tx -> MIPI CSI-2 (processor) vid_timing_gen drives axis_to_video (genlock to the camera) and hdmi_tx; isp_stats taps the linear RGB after the CCM for AE / AWB software. isp_dpc follows black level and white balance (Ramanath et al. 2005 place defect correction before white balance), so DPC_THR is in white-balanced units; with unity gains (video_processor) the order makes no difference. eof_in_o / eof_out_o pulse at the end of every frame leaving csi2_raw_unpack (first stage) / entering axis_to_video (last stage), e.g. for a frame counter. Every function can be bypassed (BYPASS register, applied at the next frame start): black level, white balance, defect correction, demosaic (raw value on R, G and B), CCM, gamma (linear 10 -> 8 bit), CSC (RGB out), scaler (stream routed around it). CTRL.TPG replaces the whole pipeline output with colour bars. The D-PHY analog front end is vendor IP: connect its per-lane HS byte outputs (PPI) to lane_data_i / lane_valid_i. The TMDS symbols leave on tmds*_o for a 10:1 serializer (tmds_serializer or vendor OSERDES) and differential output buffers. No frame buffer: the display is genlocked to the camera (CTRL.LOCK), so the display line time must be at least the camera line time; insert an external frame buffer (axis_dma + DRAM) before axis_to_video for independent frame rates. AXI4-Lite (pix_clk), ADDR_W = 15 (src/video_pipeline_map_pkg.sv): 0x0000-0x01FF pipeline registers (DECERR up to 0x3FFF), 0x4000-0x7FFF the scaler's own map (scaler_ctrl, base 0x4000). 0x000 ID RO "VPIP"; 0x004 VERSION RO ASCII "d.dd"; 0x008 DATE RO BCD mm/dd/yyyy (the ID block); register k of the old map is at 0x10 + 4 k (src/include/video_pipeline_regs.sv / .json / .md): 0x014 CTRL [0] output enable [1] HDMI (0 = DVI) [2] TPG [3] genlock [5:4] CFA (0 RGGB 1 GRBG 2 GBRG 3 BGGR) [6] CSC BT.709 (0 = BT.601) [7] insert: route the stream after isp_csc out through ins_m_axis_* and back in on ins_s_axis_* (`VP_INSERT; taken at the next frame start) 0x018 BYPASS [0] BLC [1] WB [2] DPC [3] demosaic [4] CCM [5] gamma [6] CSC [7] scaler (reset 0xC0: RGB out, no scaler) 0x01C STATUS RO [0] output locked to the camera 0x020 CSI [5:0] data type (reset 0x2B RAW10) [7:6] virtual channel 0x024 FRAME_SIZE [15:0] camera width [31:16] height 0x028-0x034 BLC R, Gr, Gb, B black levels 0x038-0x040 WB R, G, B gains Q4.8 (reset 0x100) 0x044 DPC_THR defect threshold (reset 64) 0x048-0x068 CCM coefficients c00..c22, signed Q5.10 (reset identity) 0x06C-0x074 CCM offsets R, G, B (signed) 0x078 GAMMA_ADDR table index for the next GAMMA_DATA write 0x07C GAMMA_DATA [7:0] writes table[index], index auto-increments 0x080 STAT_THR clip threshold (10-bit, reset 1000) 0x084-0x08C STAT RO sums of R, G, B (low 32 bits) of the last frame 0x090 STAT_PIX RO pixels, 0x094 STAT_CLIP RO clipped pixels 0x098 STAT_FRAMES RO 0x09C-0x0B8 VTG h active, h front porch, h sync, h back porch, v active, v front porch, v sync, v back porch 0x0BC SYNC_POL [0] hsync [1] vsync active high 0x0C0 LOCK_MAX genlock: max extra blanking lines (reset 1023) 0x0C4 START_LEVEL pixels buffered before a frame starts (reset 16) 0x0C8 AVI [6:0] VIC [9:8] picture aspect [11:10] RGB range (colour space and colorimetry follow CSC settings) 0x0CC CSI_FRAMES RO, 0x0D0 ECC_CORR RO, 0x0D4 ECC_ERR RO, 0x0D8 CRC_ERR RO, 0x0DC UNDERFLOWS RO, 0x0E0 DPC_CORR RO, 0x0E4 CSI_OVERFLOW RO (CSI overflow events: the bridge FIFO was full) 0x0E8 OUT_CTRL [0] LVDS dual link [1] LVDS 18 bpp [2] LVDS JEIDA [4] DSI video [5] DSI EoTp [7:6] DSI virtual channel [8] CSI-2 TX enable [9] CSI-2 TX YUV422 [11:10] its VC 0x0EC DSI_GAPS [15:0] LP clocks after a sync packet, [31:16] after pixels 0x0F0 CSITX_GAP LP clocks between CSI-2 TX packets 0x0F4 DSI_CMD write: queue a DSI command {[24] long, [23:16] data type, [15:0] data / word count} (sent with DSI video off) 0x0F8 DSI_CMD_BYTE write: [7:0] next payload byte of a long command 0x0FC TX_STATUS RO [0] DSI command queue busy 0x100 DSI_DROPS RO lines DSI could not send in time (dropped, or a burst that ran dry) 0x104 CSITX_DROPS RO lines CSI-2 TX could not send in time (as DSI) 0x108 CSITX_FRAMES RO frames sent by CSI-2 TX The DSI, CSI-2 TX and LVDS outputs carry the same timed video as HDMI; panels need RGB (CSC bypassed), CSI-2 YUV422 needs YCbCr (CSC on). Scaler settings: clear its CTRL.ENABLE, wait for STATUS.BUSY = 0, then change sizes / steps and enable it again (scaler_ctrl does not support changing them while a frame is being generated). 0x10C BUILD_CFG RO interfaces built: [0] CSI-2 RX [1] HDMI [2] LVDS [3] DSI [4] CSI-2 TX [5] scaler [6] insert point External interfaces are included or excluded with the `defines in configuration.sv (compiled first, see scripts/build.f); an excluded interface has no ports or logic and its registers read as 0. Clocks - byte_clk (D-PHY), pix_clk (pipeline, registers, video out). Resets - byte_rst_n, pix_rst_n, synchronous active low; assert both.

video_pipeline is an IP of the FPGA Cores 4 U digital IP library.

## Directory structure

| Path | Contents |
|------|----------|
| `src/` | RTL |
| `tb/` | self-checking testbench, tests in `tb/tests/` |
| `scripts/` | file lists (`build.f`) and flow scripts |
| `docs/` | diagrams, prompt, register table, web page |

<!-- readme:begin (generated by ip/scripts/gen_readmes.py; edits here are overwritten) -->
## Make targets

```
Targets: test (or sim), list-tests, cov, wave, yosys (or synth), docs, diagrams, diagram-check, clean
  make list-tests     name and description of each test available to run
  make test [VCD=1]   simulate; VCD=1 also dumps the testbench VCD (build/sim/<ip>/<tb>.vcd)
  make cov            simulate with Verilator code coverage (build/coverage/<ip>/summary.txt)
  make wave           simulate with the VCD dump and open it in the Surfer waveform viewer
```

## Tests

| Testbench | Test | Description |
|-----------|------|-------------|
| `video_pipeline_tb` | `video_pipeline_tb` | one test: System testbench for video_pipeline: MIPI CSI-2 camera in, HDMI / DVI out. |

## Registers

- [register map](docs/video_pipeline_regs.md): ID / VERSION / DATE at 0x00-0x08, the registers from 0x10; source [`video_pipeline_regs.json`](src/include/video_pipeline_regs.json) (edit it and run `python3 ../../scripts/regmap_gen.py src/include/video_pipeline_regs.json`), generated [`video_pipeline_regs.sv`](src/include/video_pipeline_regs.sv), [`video_pipeline_regs.xml`](src/include/video_pipeline_regs.xml), [`video_pipeline_regs.h`](src/include/video_pipeline_regs.h)

## Prompt

- [video_pipeline_prompt.md](docs/video_pipeline_prompt.md): the prompt that regenerates this block, reverse-engineered from its sources (`python3 ../../scripts/make_ip_prompts.py --only video_pipeline`)
<!-- readme:end -->

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG.

### Data flow

[![Data flow of `video_pipeline`](docs/video_pipeline_dataflow.svg)](docs/video_pipeline_dataflow.svg)
<!-- diagrams:end -->
