# video_processor

Top level of a complete video processing system, built from the IP library
(`../../ip`) and `../vision_system`:

- **Camera input**: MIPI CSI-2 into `video_pipeline` (ISP).
- **Lens correction**: `vision_system` at the pipeline's insert point.
- **Blur / sharpen**: `blur_sharpen` after `vision_system` in the same
  insert loop, with modes for blur, sharpen, sharpen then blur, blur then
  sharpen, and pass-through.
- **Scaler and outputs**: HDMI / DVI and LVDS outputs (MIPI DSI / CSI-2 optional).
- **Control**: a `py_soc` CPU that boots Python firmware from SPI flash and
  programs everything through its external register window. Its external
  interfaces are 2x UART, 2x I2C, 2x SPI, 96 GPIO and the SPI flash.

No target device or board is selected: the design is technology
independent. A board wrapper adds the PLL, the vendor D-PHYs and the
differential I/O buffers.

![system block diagram](docs/system_block_diagram.svg)

`docs/block_diagram.svg` shows the video datapath (`u_pipe` and the
serializers) in more detail.

## Directory structure

| Path | Contents |
|------|----------|
| `src/configuration.sv` | interfaces built: `VP_CSI2_RX`, `VP_HDMI`, `VP_LVDS`, `VP_DSI`, `VP_CSI2_TX`, `VP_VISION`, `VP_FILTER` (the last two imply `VP_INSERT`) |
| `src/video_processor.sv` | top level |
| `src/vs_stream_adapter.sv` | glue between the insert point and vision_system |
| `sw/video_init.py` | start-up firmware (py_soc, compiled by `pyc.py`) |
| `scripts/build.f` | RTL file list (`configuration.sv` first), relative to this directory |
| `scripts/run_sim.sh` | compile the firmware, run the system test (Icarus), `--lint` for Verilator |
| `tb/` | `video_processor_tb.sv` system test, `tb/scripts/build.f` |
| `synth/run_yosys.sh` | Yosys Xilinx 7-series synthesis (sv2v + library flow) |
| `docs/` | `system_block_diagram.*`, `block_diagram.*` (`.dot` is the source) |
| `constraints/` | board constraints (once a board is chosen) |
| `include/` | shared packages (none yet) |
| `ci/run_checked.sh` | pass/fail from the log, used by the Makefile |

## Usage

```
make sim       # system test: firmware boot, camera -> ISP -> vision_system -> HDMI / LVDS
make ip-test   # full video_pipeline system test (bit-exact ISP model, every output)
make synth     # Yosys -> build/yosys
make diagram   # re-render the diagrams
```

## Blocks

| Instance | IP module | Function |
|----------|-----------|----------|
| `u_cpu` | `py_soc` (`py_core`, `py_boot`, `py_axil_xbar`, `spi_flash_ctrl`, `uart_top` ×2, `i2c_top` ×2, `spi_top` ×2, `gpio_top` ×3, `intc_top`, `watchdog_top`, `py_sysctl`, `py_stream_port`) | control CPU, `EXT_EN = 1` |
| `u_axil_cdc` | `axi4_lite_cdc` | CPU register access cpu_clk → pix_clk |
| `u_vbus` | `py_axil_xbar` (`axi4_lite_decoder`) | video register bus |
| `u_irq_stats` | `pulse_sync` | statistics-done interrupt pix_clk → cpu_clk |
| `u_pipe` | `video_pipeline` | `csi2_rx` → ISP (`isp_*`) → insert point → `scaler_bilinear` → `vid_timing_gen` / `axis_to_video` → `hdmi_tx` / `lvds_tx` / `dsi_tx` / `csi2_tx` |
| `u_vs_adapt` | `vs_stream_adapter` (`ip_axis_fifo`) | frame admission, line gaps, return FIFO |
| `u_vision` | `vision_system` (`axis_in_ctrl`, `frame_buffer` / `ext_frame_buffer`, `axis_out_ctrl`, `coord_gen`, `bilinear`, `bicubic`, `axi_lite_regs`) | lens / barrel distortion correction |
| `u_filter` | `blur_sharpen` (`conv2d_core` ×2, `isp_window`, `ip_axil_regs`) | blur / sharpen after vision_system; MODE 0 blur, 1 sharpen, 2 sharpen→blur, 3 blur→sharpen, 4 pass-through; same latency in every mode |
| `u_tmds_ser` | `tmds_serializer` | 10:1 TMDS |
| `u_lvds_ser_a`, `u_lvds_ser_b` | `lvds_serializer` | 7:1 LVDS, links A / B |
| `u_rst_*` | `reset_sync` | one per clock domain |

### CPU address map (`mem32[]` in the firmware)

| Address | Block |
|---------|-------|
| 0x0_0100 – 0x0_C1FF | py_soc peripherals (see `py_soc.sv`) |
| 0x1_0000 – 0x1_7FFF | video_pipeline (scaler at 0x1_4000) |
| 0x1_8000 – 0x1_80FF | vision_system |
| 0x1_8200 – 0x1_83FF | blur_sharpen |

Interrupt controller source 12 is the isp_stats frame-done interrupt (use edge mode).
Sources 13–15 come from the `ext_irq_i` inputs.

## Changes made to library IP for this design

All of these default off, so other users of the library are unaffected.

- **`py_soc`**: `EXT_EN` adds an external AXI4-Lite master window at
  0x1_0000–0x1_FFFF (`m_ext_axil_*`). `ext_irq_i[3:0]` drives interrupt
  controller sources 12–15. Its self-test still passes.
- **`video_pipeline`**: `` `VP_INSERT`` adds an insert point after
  `isp_csc` (`ins_m_axis_*` / `ins_s_axis_*`). CTRL[7] enables it and the
  route switches only at a frame start. BUILD_CFG[6] reports it. The
  system test still passes.

## Limits

- **No back-pressure from vision_system:** its output never stalls and it
  buffers a whole frame. So `vs_stream_adapter` admits a camera frame only
  when vision_system is idle and its return FIFO is empty, and drops the
  other frames. The return FIFO (`VS_RET_FIFO`) must hold a whole frame.
  For full-size frames, use an external frame buffer.
- **Genlock required:** keep CTRL.LOCK set. There is no frame buffer to
  repeat a frame, so each display frame waits in vertical blanking for the
  next corrected frame. The display then runs at vision_system's output
  rate, which is below the camera rate (in the test, 8 of 11 camera frames
  are processed and the rest are dropped while vision_system is busy). A
  free-running display would show black frames in between.
- **Frame size:** vision_system frames are at most 720 × 720. Its on-chip
  frame buffer is large, so use `VS_USE_EXT_FB = 1` (SDRAM) on real devices.
- **Precision:** vision_system's identity correction is accurate to ±1 LSB,
  the same tolerance its own regression uses.

## Verification

- **`make sim`**: the testbench programs nothing itself. In order:
  1. `py_soc` boots `sw/video_init.py` from a SPI flash model.
  2. The firmware releases the camera reset (GPIO), configures vision_system,
     blur_sharpen (MODE 3, blur then sharpen) and video_pipeline over the
     external window, and enables the statistics interrupt.
  3. It starts the camera model with an I2C write.
  4. It counts frame interrupts and turns on the "running" LED.
  5. vision_system's output is checked against the camera image (±1 LSB,
     its own tolerance). The HDMI and LVDS serial outputs are decoded back
     into images and must equal the reference blur-then-sharpen of that
     output exactly.
- **`make ip-test`**: the `video_pipeline` system test, with a bit-exact
  ISP model and every output checked.

## Next steps

- **Board wrapper:** PLL / MMCM, vendor D-PHY RX / TX, OSERDES instead of
  the behavioural serializers at 1080p, OBUFDS, and constraints.
- **Frame buffer:** an external frame buffer (`axis_dma` + DRAM) to remove
  the frame-size and frame-rate limits of the vision_system path.
