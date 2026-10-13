# video_processor

Top level of a complete video processing system, built from the IP library
(`../../ip`) and `../vision_system`:

- **Camera input**: MIPI CSI-2 into `video_pipeline` (ISP).
- **Lens correction**: `vision_system` at the pipeline's insert point.
- **Blur / sharpen**: `blur_sharpen` after `vision_system` in the same
  insert loop, with modes for blur, sharpen, sharpen then blur, blur then
  sharpen, and pass-through.
- **Target tracking and symbol overlay**: `object_tracker` finds a target
  (its bounding box inside a search window) in every frame, the firmware
  tracks it from frame to frame, and `symbol_overlay` draws a dashed box
  around it over the video (up to 4 symbols: boxes, filled boxes,
  crosshairs, solid or dashed).
- **Scaler and outputs**: HDMI / DVI and LVDS outputs (MIPI DSI / CSI-2 optional).
- **Control**: a `py_soc` CPU that boots Python firmware from SPI flash and
  programs everything through its external register window. Its external
  interfaces are 2x UART, 2x I2C, 2x SPI, 96 GPIO and the SPI flash.

No target device or board is selected: the design is technology
independent. A board wrapper adds the PLL, the vendor D-PHYs and the
differential I/O buffers.

![system block diagram](docs/system_block_diagram.svg)

`docs/block_diagram.svg` shows the video datapath (`u_pipe` and the
serializers) in more detail, `docs/tracking_diagram.svg` the tracking loop.

![pedestrian tracking](docs/tracking_diagram.svg)

### Clocks and resets

One board clock, `ref_clk` (33.333 MHz), feeds the clock generator in the
CPU system (`py_soc` `u_clkgen`, [`ip/clock/clk_gen`](../../ip/clock/clk_gen)):
two all-digital PLLs ([`ip/clock/dpll`](../../ip/clock/dpll)) make every
clock of the design except the camera byte clock, which the D-PHY RX
recovers from the camera.

| Clock | Default | Ratio (parameters) | Used by |
|-------|---------|--------------------|---------|
| `cpu_clk` | 200 MHz | ref × `CPU_M` / (`CPU_D` × `CPU_O`) = × 24 / 4 (CPU PLL oscillator 800 MHz) | `py_soc`, CPU side of the crossings |
| `pix_clk` | 100 MHz | `cpu_clk` × `VID_M` / (`VID_D` × `PIX_O`) = × 35 / 70 (video PLL oscillator 7 GHz) | core logic: video pipeline, registers, vision_system, blur_sharpen, SDRAM |
| `tmds_ser_clk` | 1 GHz | ÷ `TMDS_O` = 7 (10 × `pix_clk`) | HDMI serializer |
| `lvds_ser_clk` | 700 MHz | ÷ `LVDS_O` = 10 (7 × `pix_clk`, single link; 20 for dual link) | LVDS serializers |
| `tx_byte_clk` | 125 MHz | ÷ `TXB_O` = 56 | MIPI DSI / CSI-2 TX (1 Gbit/s per lane) |
| `byte_clk` | 125 MHz | input from the D-PHY RX | CSI-2 RX |

The video PLL outputs share one oscillator, so the serial clocks are phase
aligned with `pix_clk` (as the serializers require). SYSCTL `CLK_EN`
(0x0114) gates each video clock: the core and MIPI byte clocks run from
reset, the firmware turns the display serial clocks on at its video set-up.
`CLK_STATUS` (0x0118) shows the lock.

Each CPU peripheral has its own parameter set (rate, and the TX / RX FIFO
depths of its `py_stream_port`, 16 words by default):

| Peripheral | Use | Rate parameter | Default |
|------------|-----|----------------|---------|
| UART 0 | debug console | `UART0_BAUD` | 115200 baud |
| UART 1 | host / control link | `UART1_BAUD` | 115200 baud |
| I2C 0 | camera sensor CCI | `I2C0_HZ` | 400 kHz (fast mode) |
| I2C 1 | HDMI DDC / EDID, EEPROM | `I2C1_HZ` | 100 kHz (standard mode) |
| SPI 0 | panel initialisation / touch | `SPI0_HZ`, `SPI0_DATA_W` | 10 MHz, 16-bit words |
| SPI 1 | ADC, sensors | `SPI1_HZ`, `SPI1_DATA_W` | 2 MHz, 16-bit words |
| SPI NOR flash | firmware | `FLASH_CLKDIV` | 3 (33 MHz at boot) |

FIFO parameters: `UART0_TX_FIFO` / `UART0_RX_FIFO`, ... `FLASH_TX_FIFO` /
`FLASH_RX_FIFO`. The testbench overrides the rates for a short simulation.

For synthesis only the PLL oscillators (`dpll_dco`, oscillator + phase
read-out) are black boxes; the loop logic (`dpll_ctrl`) is synthesizable.
On an FPGA, replace them, or `clk_gen`, with the device PLL / MMCM. The
7 GHz video oscillator suits the simulation model; a device PLL would use
separate outputs per ratio.

![clock generation and distribution](docs/clock_diagram.svg)

`arst_n` resets only the CPU system (`py_soc`), held until its CPU PLL
locks. The core logic is released by the firmware through SYSCTL
`CORE_RESET` (`core_rst_n_o`, only while the video PLL is locked),
synchronised once per clock domain by `reset_sync`; every CPU reset
(`arst_n`, loss of lock or the watchdog) clears `CORE_RESET` again.

![reset generation and distribution](docs/reset_diagram.svg)

## Directory structure

| Path | Contents |
|------|----------|
| `src/configuration.sv` | interfaces built: `VP_CSI2_RX`, `VP_HDMI`, `VP_LVDS`, `VP_DSI`, `VP_CSI2_TX`, `VP_VISION`, `VP_FILTER`, `VP_TRACK` (the last three imply `VP_INSERT`) |
| `src/video_processor.sv` | top level |
| [`../../ip/video/vs_stream_adapter`](../../ip/video/vs_stream_adapter) | library IP: glue between the insert point and vision_system |
| [`../../ip/video/frame_counter`](../../ip/video/frame_counter) | library IP: frame counters with end-of-frame interrupts (frames out of the first pipeline stage and into the last one) |
| [`../../ip/video/object_tracker`](../../ip/video/object_tracker) | library IP: target search / measurement: bounding box, count and sums of the object pixels in a search window, per frame |
| [`../../ip/video/symbol_overlay`](../../ip/video/symbol_overlay) | library IP: symbols drawn over the video stream: 4 objects, rectangle outline / filled / crosshair, solid or dashed, colour or blend |
| `sw/video_proc.py` | firmware: the program (interrupt handler, `main`); imports the modules below, `pyc.py` builds one flash image from all of them |
| `sw/video_init.py` | CPU initialisation (boot report, peripheral self-test, CPU register dump, UART text output), sections 1-3 |
| `sw/video_regs.py` | addresses, register offsets and bit values of the video blocks |
| `sw/camera.py` | camera control over I2C 0 (frame gap, frame size, stream on), image format pin and ISP format |
| `sw/video_setup.py` | `frame_size`, video set-up (section 4), video start (section 6) |
| `sw/video_dump.py` | video register display at the end of the set-up (section 5) |
| `sw/events.py` | frame event transcript from `frame_counter`'s event log: one line per event, in the order they happened, with the time |
| `sw/sequence.py` | frame counters and image sequence (section 7) |
| `sw/search.py` | `object_tracker` search windows (whole frame, around the predicted box) |
| `sw/tracker.py` | `object_tracker` set-up and the SEARCH / TRACK / COAST state machine with the prediction |
| `sw/overlay.py` | `symbol_overlay`: the dashed tracking box |
| `sw/tracking.py` | pedestrian tracking (section 8) |
| `scripts/build.f` | RTL file list (`configuration.sv` first), relative to this directory |
| `scripts/run_sim.sh` | compile the firmware, run the system test (Icarus), `--lint` for Verilator |
| `tb/` | `video_processor_tb.sv` system test, its test tasks in `tb/tests/video_processor_tests.sv`, `tb/scripts/build.f`; it also uses the library testbench models `ip/video/video_tb_lib/gif_io.sv` (animated GIF reader / writer) and `track_ref.sv` (tracker and overlay models) |
| `tb/images/` | `pedestrian_walk.gif`: the tracking test's input (128 × 96, 50 frames, 5 s, black-and-white street video), `.truth.txt` its true boxes |
| `tb/scripts/make_pedestrian_gif.py` | regenerates `pedestrian_walk.gif` (pure Python) |
| `synth/run_yosys.sh` | Yosys Xilinx 7-series synthesis (sv2v + library flow) |
| `docs/` | `system_block_diagram.*`, `block_diagram.*`, `clock_diagram.*`, `reset_diagram.*`, `tracking_diagram.*` (`.dot` is the source) |
| `constraints/` | board constraints (once a board is chosen) |
| `include/` | shared packages (none yet) |
| `ci/run_checked.sh` | pass/fail from the log, used by the Makefile |

## Usage

`make help` prints the same summary. Every option is `NAME=value` on the `make` command line;
`scripts/run_sim.sh` takes the equivalent `--` switches (last column).

### Targets

| Command | What it does |
|---------|--------------|
| `make help` | print the targets, options and examples |
| `make sim` | system test (Icarus): firmware boot, camera → ISP → vision_system → blur_sharpen → tracker / overlay → HDMI / LVDS, image test, tracking GIF; fails on a bad result |
| `make wave` | the system test with a VCD dump, opened in the Surfer waveform viewer (pass or fail) |
| `make list-tests` | name and description of every test the system test runs |
| `make lint` | Verilator lint of the RTL (warnings only) |
| `make ip-test` | the library `video_pipeline` system testbench (bit-exact ISP model, every output) |
| `make synth` | Yosys Xilinx 7-series synthesis → `build/yosys` |
| `make cov` | sim + ip-test with Verilator code coverage → `build/coverage/summary.txt` |
| `make ci` | sim + ip-test + synth |
| `make diagram` | re-render `docs/*.dot` → `.svg` / `.png` (Graphviz) |
| `make clean` | remove `build/` and `ci/logs/` |

### Simulation options (`sim`, `wave`, `cov`)

| Option | Description | `run_sim.sh` |
|--------|-------------|--------------|
| `QUICK=1` | skip the register dumps of sections 3 and 5 in the firmware report (GPIO0[31] strap): about 3 h faster; the set-up old / new value reports still run | `--quick` |
| `IDEAL_PLL=1` | clock generator PLLs as ideal clock toggles at the exact ratios: faster, PLL lock behaviour not modelled | `--ideal-pll` |
| `VCD=1` | dump all signals to `build/sim/video_processor_tb.vcd` (large: use with a window) | `--vcd` |
| `VCD_START_US=<n>` | start the VCD dump at n µs of simulated time (with `VCD=1` or `make wave`) | `--vcd-start=<n>` |
| `VCD_STOP_US=<n>` | stop the VCD dump at n µs of simulated time (with `VCD=1` or `make wave`) | `--vcd-stop=<n>` |
| `GIF=<file>` | tracking test input: any animated GIF (default `tb/images/pedestrian_walk.gif`); its size sets the frame size, fitted to 320 × 240; a relative path is from this directory | `--gif=<file>` (or `GIF_IN=<file>` in the environment) |
| `GIF_BW=1` | convert a colour input GIF to black and white (BT.601 luma); without it a colour GIF runs through the pipeline in colour (RGGB mosaic, ISP demosaic) | `--gif-bw` |
| `GIF_FRAMES=<n>` | send only the first n frames of the tracking GIF (shorter run; default every frame) | `--gif-frames=<n>` |

`scripts/run_sim.sh --lint` runs the Verilator lint and `--list-tests` lists the tests, as the
make targets do.

### Results (`build/sim/`)

| File | Contents |
|------|----------|
| `video_processor_tb.log` | simulation log, ends with TEST PASSED / TEST FAILED |
| `cpu_bootup.txt` | the firmware's UART 0 report |
| `output_images/<module>_<c\|m>_<n>_output.ppm` | image test: every image at every module output |
| `gif-input/<name>_<w>x<h>.gif` | the tracking sequence as the camera sent it (`<name>_bw.gif` too when converted) |
| `gif-output/<name>_tracked.gif` | the HDMI output with the dashed tracking box, same frame times as the input |

### Examples

```
make sim                                                     # full system test, default pedestrian GIF (long: real PLL models)
make sim QUICK=1 IDEAL_PLL=1                                 # fastest full run
make sim QUICK=1 IDEAL_PLL=1 GIF_FRAMES=6                    # quick check of the tracking flow on the first 6 GIF frames
make sim GIF=$HOME/clips/walk.gif                            # track in your own GIF (colour stays colour)
make sim GIF=$HOME/clips/walk.gif GIF_BW=1                   # your own colour GIF, converted to black and white first
make sim GIF=../my_clips/street.gif GIF_FRAMES=20 QUICK=1    # relative path (from this directory), first 20 frames
make sim VCD=1 VCD_START_US=2000 VCD_STOP_US=2200            # waveforms of a 200 µs window only
make wave QUICK=1 IDEAL_PLL=1 VCD_START_US=2000 VCD_STOP_US=2100   # same, then open Surfer
make cov QUICK=1                                             # coverage of the quick run
scripts/run_sim.sh --quick --ideal-pll --gif=walk.gif --gif-bw --gif-frames=10   # the same options without make
```

## Blocks

| Instance | IP module | Function |
|----------|-----------|----------|
| `u_cpu` | `py_soc` (`clk_gen` (`dpll` ×2: `dpll_ctrl`, `dpll_dco`), `py_core`, `py_boot`, `py_axil_xbar`, `spi_flash_ctrl`, `uart_top` ×2, `i2c_top` ×2, `spi_top` ×2, `gpio_top` ×3, `intc_top`, `watchdog_top`, `py_sysctl`, `py_stream_port`) | CPU system: every clock (`CLKGEN_EN = 1`), control CPU, `EXT_EN = 1` |
| `u_axil_cdc` | `axi4_lite_cdc` | CPU register access cpu_clk → pix_clk |
| `u_vbus` | `py_axil_xbar` (`axi4_lite_decoder`) | video register bus |
| `u_irq_stats` | `pulse_sync` | statistics-done interrupt pix_clk → cpu_clk |
| `u_frame_cnt` | `frame_counter` (`ip_axil_regs`) | COUNT0: frames out of `csi2_raw_unpack` (first stage), COUNT1: frames into `axis_to_video` (last stage); an end-of-frame interrupt per counter |
| `u_irq_frame0/1` | `bit_sync` | frame-counter interrupts pix_clk → cpu_clk |
| `u_pipe` | `video_pipeline` | `csi2_rx` → ISP (`isp_*`) → insert point → `scaler_bilinear` → `vid_timing_gen` / `axis_to_video` → `hdmi_tx` / `lvds_tx` / `dsi_tx` / `csi2_tx` |
| `u_vs_adapt` | `vs_stream_adapter` (`ip_axis_fifo`) | frame admission, line gaps, return FIFO |
| `u_vision` | `vision_system` (`axis_in_ctrl`, `frame_buffer` / `ext_frame_buffer`, `axis_out_ctrl`, `coord_gen`, `bilinear`, `bicubic`, `axi_lite_regs`) | lens / barrel distortion correction |
| `u_filter` | `blur_sharpen` (`conv2d_core` ×2, `isp_window`, `ip_axil_regs`) | blur / sharpen after vision_system; MODE 0 blur, 1 sharpen, 2 sharpen→blur, 3 blur→sharpen, 4 pass-through; same latency in every mode |
| `u_track` | `object_tracker` (`ip_axil_regs`) | passive tap after blur_sharpen: per frame, the box of the target pixels in the search window |
| `u_overlay` | `symbol_overlay` (`ip_axil_regs`) | last in the insert loop: draws the CPU's symbols (the dashed tracking box) |
| `u_tmds_ser` | `tmds_serializer` | 10:1 TMDS |
| `u_lvds_ser_a`, `u_lvds_ser_b` | `lvds_serializer` | 7:1 LVDS, links A / B |
| `u_rst_*` | `reset_sync` | one per core clock domain, only from the CPU system's core reset output (the cpu_clk domain reset comes from `py_soc`) |

### CPU address map (`mem32[]` in the firmware)

The map is the package `src/video_processor_map_pkg.sv` (it imports
`ip/cpu/py_soc/src/py_soc_map_pkg.sv` and `ip/video/video_pipeline/src/video_pipeline_map_pkg.sv`).
The pixel-domain decoder (`u_vbus`), py_soc's crossbar and the firmware (`pyc.py -I ...`:
`from video_processor_map_pkg import *`) all read their addresses from these packages.
Every window starts with the block's ID block: ID (4 ASCII characters), VERSION (ASCII
`d.dd`) and DATE (BCD mm/dd/yyyy) at +0x00 / +0x04 / +0x08, the registers from +0x10.

| Address | Block | ID | Register map |
|---------|-------|----|--------------|
| 0x0_0100 – 0x0_C1FF | py_soc peripherals | SCTL, INTC, WDOG, GPIO, UART, I2CM, SPIM, SPFL, PORT | `py_soc_map_pkg.sv`, each IP's `docs/<ip>_regs.md` |
| 0x1_0000 – 0x1_3FFF | video_pipeline | VPIP | `ip/video/video_pipeline/docs/video_pipeline_regs.md` |
| 0x1_4000 – 0x1_7FFF | its scaler (scaler_bilinear) | BLIN | `ip/scalers/scaler_ctrl/src/scaler_ctrl.sv` (common map) |
| 0x1_8000 – 0x1_80FF | vision_system | VSYS | `image_processing/vision_system/docs/vision_system_regs.md` |
| 0x1_8200 – 0x1_83FF | blur_sharpen | BLSH | `ip/video/blur_sharpen/docs/blur_sharpen_regs.md` |
| 0x1_8400 – 0x1_84FF | frame_counter | FCNT | `ip/video/frame_counter/docs/frame_counter_regs.md` |
| 0x1_8500 – 0x1_85FF | object_tracker | OTRK | `ip/video/object_tracker/docs/object_tracker_regs.md` |
| 0x1_8800 – 0x1_8BFF | symbol_overlay | SOVL | `ip/video/symbol_overlay/docs/symbol_overlay_regs.md` |

Interrupt controller sources:

| Source | Interrupt |
|--------|-----------|
| 12 | isp_stats frame done (use edge mode) |
| 13 | end of frame at the first pipeline stage (`frame_counter` STATUS[0], level, write 1 to clear) |
| 14 | end of frame at the last pipeline stage (`frame_counter` STATUS[1], level, write 1 to clear) |
| 15 | `ext_irq_i` (the firmware's self-test also uses it as its software interrupt) |

### frame_counter, object_tracker and symbol_overlay registers

The generated register documents above list every register. The ones the firmware uses most:

| Address | Register | Description |
|---------|----------|-------------|
| 0x1_8418 / 0x1_841C | frame_counter IRQ_EN / STATUS | [0] first stage, [1] last stage; STATUS write 1 to clear |
| 0x1_8424 – 0x1_842C | frame_counter EVENT / EVENT_TIME / EVENT_POP | event log: oldest event ([31] valid, [26:24] channel, [23:0] count), its time (µs), remove it |
| 0x1_8430 + 4 n | frame_counter COUNT[n] | 0 first stage, 1 last stage, 2 / 3 into / out of vision_system, 4 tracker |
| 0x1_8450 / 0x1_8454 | frame_counter TIME / EV_EN | µs now; channels logged (128-entry log) |
| 0x1_8518 – 0x1_8528 | object_tracker CTRL, FRAME_SIZE, THRESH, WIN_X, WIN_Y | [0] enable, [1] dark object, [11:8] MIN_RUN; frame size; luma threshold; search window |
| 0x1_852C – 0x1_8544 | object_tracker FRAMES, COUNT, BOX_X, BOX_Y, SUM_X, SUM_Y, STATUS | the last frame's measurement |
| 0x1_8818 / 0x1_881C / 0x1_8824 | symbol_overlay CTRL / COMMIT / FRAME_NUM | enable; apply the object and text registers at the next frame start; BCD frame number |
| 0x1_8850 + 16 i | symbol_overlay OBJ_CTRL / X / Y / COLOR[i] | [0] enable, [2:1] shape, [3] dashed, [11:8] width, [14:12] dash log2; box; colour |
| 0x1_8910 + 16 j, 0x1_8A10 + 16 j | symbol_overlay TXT_CTRL / POS / COLOR[j], TXT_CHARS[j] | text j: [0] enable, [2:1] scale, [3] backdrop, [4] + frame number, [12:8] length; 4 character words |

Object 0 is drawn on top; the 4 texts (3 × 5 font in 4 × 6 cells, `overlay_font_pkg`,
lowercase drawn as capitals) are on top of the objects. The tracking firmware uses object 0
as a 1-pixel dashed green rectangle (dashes of 4) and three texts on a darkened backdrop:
the image name in the upper left corner (read from the camera's registers 0x40–0x4F), a
clock in the upper right (`HH:MM:SS.mmm`, time since the core logic started, from
`frame_counter` TIME) and `frame number <n>` in the lower left, the number counted by the
overlay itself at every frame start (FRAME_NUM = 1 for the first frame of the sequence), so
it is right on every frame even when the report runs behind.

The end-of-frame markers come from `video_pipeline` (`eof_in_o`, `eof_out_o`): the last
pixel of a frame, counted in lines of FRAME_SIZE height (first stage) and VTG v-active
height (last stage).

### Reset and start-up

- **`arst_n`** (external, asynchronous, active low) resets the CPU system. Its release
  starts the CPU PLL; once it locks (about 12 µs), the boot starts: `py_boot` loads the firmware from SPI flash, then the firmware tests
  the CPU peripherals.
- **Core logic reset:** every other block (`video_pipeline`, `vision_system`,
  `blur_sharpen`, `frame_counter`, the serializers) stays in reset until the firmware,
  after a successful boot with every self-test passed, writes 1 to py_soc SYSCTL
  `CORE_RESET` (0x0110). Its output, `core_rst_n_o`, is the core logic's only reset,
  synchronised into each core clock domain; the `core_rst_n_o` port shows it to the board.
  `core_rst_n_o` is released only while the video PLL is locked. `arst_n` reaches the
  core logic through the CPU system: it asserts py_soc's CPU reset at once, which
  clears `core_rst_n_o` asynchronously and `CORE_RESET` with it.
- **Self-test failed:** the core logic stays in reset and the firmware skips the video sections.
- **Watchdog reset:** resets the CPU and clears `CORE_RESET`, so the core logic goes back
  into reset until the firmware has booted and released it again.

### Firmware

`sw/video_proc.py` is the program; its `from <module> import *` lines pull in the other
modules of `sw/` (`pyc.py` inlines each one once, into one global namespace and one flash
image; see the directory table). The video starts only after the CPU initialisation is
complete. The UART 0 report (`build/sim/cpu_bootup.txt` in simulation):

1. Boot-up sequence, 2. CPU peripheral self-test, 3. CPU register dump (`video_init.py`;
   the dump is skipped with the GPIO0[31] quick-simulation strap, `run_sim.sh --quick`).
   With every self-test passed the CPU then releases the core logic reset (SYSCTL
   `CORE_RESET`, read back as a [PASS] line); otherwise the video sections are skipped.
4. Video set-up, with the camera not streaming: camera out of reset, camera frame gap,
   vision_system, blur_sharpen, video_pipeline, image format, frame counter and statistics
   interrupts. The frame gap is the time from the end of one camera frame to the start of
   the next: `FRAME_GAP_NS` (1280 ns) written to the camera's control registers 0x20–0x21
   (high byte first, ns) over I2C 0 and read back. The image format pin GPIO0[30]
   (1 monochrome: every ISP stage bypassed; 0 colour: RGGB demosaic on) is read here and on
   every change (GPIO0 edge interrupt, serviced first so it lands within the frame gap);
   GPIO0[2] shows the format programmed.
   Every register write of the set-up is reported as it happens (`wreg()` in
   `video_init.py`): the module and register name, the value before the write, the value
   read back after it, and one or two lines on what the change does, e.g.

   ```
   vision_system SCALE
     old value 0x00000000
     new value 0x00010000
     zoom applied after the correction, Q16.16: 0x10000 = 1.0, no
     edge crop, output pixel (x, y) samples input pixel (x, y)
   ```

   The tracking set-up of section 8 (frame size from the camera, tracker, overlay objects
   and texts) is reported the same way. Not reported: the per-frame updates while tracking
   (box, search window, clock text, commit; they would hold up the real-time transcript),
   the bytes pushed into the I2C data FIFO, and the interrupt handler's acknowledges.
   Names and descriptions are `strings()` entries in the flash string table; the firmware
   is compiled with `pyc.py --code-aw 14 --str-slots 1024 --split-consts` (16 KB code
   memory: video_processor `CPU_CODE_AW = 14`; 128 KB testbench flash).
5. End of the video set-up: every video_processor register with its address, name, short
   description and value: the CPU peripherals (SYSCTL, INTC, WDT, GPIO0-2, UART0-1,
   I2C0-1, SPI0-1, flash) and the video blocks (video_pipeline, scaler, vision_system,
   blur_sharpen, frame_counter, object_tracker, symbol_overlay objects and texts). Always
   skipped with the quick strap (`--quick`, `QUICK=1`) to save about 3 hours of simulation.
6. Video start: camera "stream on", frames counted, outputs checked.
7. Frame counters and image sequence: the interrupt handler reads COUNT0 at every
   first-stage end of frame (interrupt 13) and COUNT1 at every last-stage end of frame
   (interrupt 14). Once the pipeline is idle the firmware clears every count and the event
   log, so the camera board's image sequence (GPIO0[29] = 1) is counted from 0. The report
   is a transcript of the true sequence of events: `frame_counter` logs every frame marker
   in the order it happened with its time (µs), and the firmware reports each one as a
   line, oldest first, for example (illustrative times)

   ```
     [9481 us] vision_system takes frame 1
     [9483 us] IRQ 13: COUNT0 = 1, end of frame at the first stage
     [9497 us] vision_system outputs frame 1
     [9512 us] tracker frame 1
     [9514 us] IRQ 14: COUNT1 = 1, end of frame at the last stage
   ```

   (the frame is streamed, so vision_system takes it while it is still leaving the first
   stage). When the text falls behind the frames, the lines still come in the true order
   with the true times. Frames follow each other at least the frame gap apart; a frame
   that arrives while vision_system is busy is dropped by `vs_stream_adapter` before the last
   stage, so the test's camera paces its images and all 8 reach the last stage (count 8).
8. Pedestrian tracking: the firmware reads the tracking sequence's frame size from the
   camera's control registers 0x30–0x33 (width, height, high byte first) over I2C 0 and
   reprograms every block for it (`frame_size`: camera input, vision_system,
   blur_sharpen, object_tracker, display), sets the tracker (luma below 80, runs of 2+ pixels, whole frame) and
   turns the overlay on (stage 170). For each frame of the camera's tracking sequence
   (GPIO0[29] = 1) it reads the tracker's box and runs SEARCH → TRACK (→ COAST on a miss,
   back to SEARCH after 4 misses): the centre velocity is smoothed, the box size grows at once
   and shrinks slowly, and the dashed box and the search window (box + 12 pixels) move to the
   predicted position for the next frame. py_core has no multiply or divide: centres are kept
   × 2 and everything uses adds and shifts. The transcript logs the first stage, the tracker
   and the last stage of every frame (fewer lines, so the report keeps up with the frames);
   the tracking step runs on the tracker's event and completes its line
   (`[t us] tracker frame n: TRACK x a-b y c-d, p px`), then the count of frames with the
   pedestrian found.
9. Summary and END OF REPORT.

## Library IP added for this design

`vs_stream_adapter`, `frame_counter`, `object_tracker` and `symbol_overlay` live in the
library (`ip/video/<ip>`), each with its own self-checking testbench and tests
(`make -C ../../ip/video/<ip> test`, `VCD=1`, `make cov`, `make synth`, `make list-tests`).
`vs_stream_adapter`'s line gap is now a parameter (default 8); this design passes
`barrel_pkg::LINE_GAP_CYCLES + 3`, the value it had before.

## Changes made to library IP for this design

All of these default off, so other users of the library are unaffected.

- **`py_soc`**: `EXT_EN` adds an external AXI4-Lite master window at
  0x1_0000–0x1_FFFF (`m_ext_axil_*`). `ext_irq_i[3:0]` drives interrupt
  controller sources 12–15. SYSCTL `CORE_RESET` (0x0110) drives the new
  `core_rst_n_o` output, the reset of the logic outside the CPU (held low from
  every system reset until the firmware writes 1). Its self-test passes and
  now also checks `core_rst_n_o`.
- **`video_pipeline`**: `` `VP_INSERT`` adds an insert point after
  `isp_csc` (`ins_m_axis_*` / `ins_s_axis_*`). CTRL[7] enables it and the
  route switches only at a frame start. BUILD_CFG[6] reports it. The
  `eof_in_o` / `eof_out_o` end-of-frame marker outputs (one-clock pulses,
  unused by other designs) feed the frame counter. The system test still
  passes.
- **`pyc.py`**: `from <module> import *` of a sibling file inlines it (one
  firmware image from several files), and the flash string table has 512
  slots.

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
- **Tracking:** the tracker segments by brightness (a dark target on a lighter scene, or
  the reverse with CTRL[1] = 0); clutter as dark as the target inside the search window
  joins its box. The box drawn on a frame comes from the previous frame's measurement,
  moved by the predicted velocity.
- **Frame size:** vision_system frames are at most 720 × 720. Its on-chip
  frame buffer is large, so use `VS_USE_EXT_FB = 1` (SDRAM) on real devices.
- **Precision:** vision_system's identity correction is accurate to ±1 LSB,
  the same tolerance its own regression uses.

## Verification

- **`make sim`** (`scripts/run_sim.sh`, `--quick` skips the register dumps of sections 3 and 5): the
  simulation runs in a local work directory (`SIM_WORK_DIR`, default under `$TMPDIR`)
  because writing its files inside a cloud-synced folder such as OneDrive slows it down
  many times; the results are copied back to `build/sim/`. The testbench programs nothing
  itself. In order:
  1. `py_soc` boots the firmware (`sw/video_proc.py` + `sw/video_init.py`) from a SPI flash model.
     The core logic must stay in reset until the CPU releases it after its self-test
     (`test_core_reset`).
  2. The firmware releases the camera reset (GPIO), configures vision_system,
     blur_sharpen (MODE 3, blur then sharpen) and video_pipeline over the
     external window, and enables the statistics interrupt.
  3. It starts the camera model with an I2C write.
  4. It counts frame interrupts and turns on the "running" LED.
  5. vision_system's output is checked against the camera image (±1 LSB,
     its own tolerance). The HDMI and LVDS serial outputs are decoded back
     into images and must equal the reference blur-then-sharpen of that
     output exactly.
  6. Image test: 4 colour and 4 monochrome images are read from
     `build/sim/input_images/` (`frame_c_<n>_input.ppm`, `frame_m_<n>_input.ppm`; generated
     with moving shapes when missing, colour as P6, monochrome as P5). The camera model sends
     them one RAW10 frame each (colour as an RGGB Bayer mosaic), each once vision_system can
     take it and at least the programmed frame gap after the previous one; it sets the format pin for the next image as soon
     as the previous frame's last line is out, so the firmware reprograms the ISP during the
     gap. The frame of each image at the output of every module it reaches (`csi2_raw_unpack`, `isp_blc_wb`, `isp_dpc`,
     `isp_demosaic`, `isp_ccm`, `isp_gamma`, `isp_csc`, `vision_system`, `blur_sharpen`,
     `hdmi_tx`, `lvds_tx`) is saved as `build/sim/output_images/<module>_<c|m>_<n>_output.ppm`
     (P6) and checked: monochrome passes the ISP unchanged, colour keeps every native
     Bayer sample and comes out in colour, vision_system within ±1 LSB, blur_sharpen
     equal to its model, HDMI and LVDS equal to blur_sharpen. Every image must reach
     `isp_csc` and pass the whole pipeline: the camera paces the sequence (each image once
     vision_system can take it, at least the frame gap after the previous one), so
     `vs_stream_adapter` drops none, and the frame counter must count all 8 at the first
     and at the last stage.
     The report must list the counts 1, 2, 3, ... with no gaps.
  7. Tracking test: the input GIF (`tb/images/pedestrian_walk.gif` by default) is read by
     the testbench's GIF reader (`ip/video/video_tb_lib/gif_io.sv`) and sent by the camera, one frame per GIF
     frame, after the firmware's set-up for its size. The frame size follows the GIF: its
     own width (rounded down to a multiple of 4, RAW10 packing) and height (even, Bayer),
     scaled down with the same aspect ratio when larger than 320 × 240 (the testbench's
     `MAX_W`, `VS_RET_FIFO` and HDMI sink are sized for that), loaded into the camera
     model's registers 0x30–0x33 at start-up. Every frame is captured at the tracker
     input, the overlay output and on HDMI: the tracker's results and the overlay output
     must equal the models (`ip/video/video_tb_lib/track_ref.sv`), HDMI must equal the overlay output, the
     pedestrian must be found in the first frame and, from the second, be inside the dashed
     box (its centre, and at least 75 % of it from the third). The HDMI frames are written
     as `build/sim/gif-output/<name>_tracked.gif` (`pedestrian_walk_tracked.gif` by default; same frame times) and read back; the
     input sequence as the camera sent it goes to `build/sim/gif-input/<name>_<w>x<h>.gif`.
     Options (`make sim ...` / `scripts/run_sim.sh ...`): `GIF=<file>` / `--gif=<file>` any
     animated GIF; a colour GIF goes through the pipeline in colour
     (RGGB mosaic, ISP demosaic), or `GIF_BW=1` / `--gif-bw` converts it to black and white
     (BT.601 luma, saved as `gif-input/<name>_bw.gif`); `GIF_FRAMES=<n>` /
     `--gif-frames=<n>` sends only the first n frames. The LVDS serial clock is stopped for
     this test (LVDS is checked before it).
  8. The UART 0 report (`build/sim/cpu_bootup.txt`) must end with no [FAIL] line, and its
     frame event transcript must be the true sequence: every event line is the next marker
     `frame_counter` logged (channel, count and time, in the order the testbench saw the
     markers), counts run 1, 2, 3, ... per channel, times never go back, and every frame is
     reported at all 5 points in section 7 and at the first stage, tracker and last stage in
     section 8.
- **`make ip-test`**: the `video_pipeline` system test, with a bit-exact
  ISP model and every output checked.

## Next steps

- **Board wrapper:** PLL / MMCM, vendor D-PHY RX / TX, OSERDES instead of
  the behavioural serializers at 1080p, OBUFDS, and constraints.
- **Frame buffer:** an external frame buffer (`axis_dma` + DRAM) to remove
  the frame-size and frame-rate limits of the vision_system path.

<!-- readme:begin (generated by ip/scripts/gen_readmes.py; edits here are overwritten) -->
## Make targets

```
Targets:
  make help          this text
  make sim           video_processor system test (Icarus): boot, camera -> ISP -> vision_system -> blur_sharpen -> tracker / overlay -> HDMI / LVDS, image test, tracking GIF
  make wave          the system test with a VCD dump, opened in the Surfer waveform viewer (pass or fail)
  make list-tests    name and description of every test the system test runs
  make lint          Verilator lint of the RTL (warnings only)
  make ip-test       the library video_pipeline system testbench (bit-exact ISP model, every output)
  make synth         Yosys Xilinx 7-series synthesis -> build/yosys
  make cov           sim + ip-test with Verilator code coverage -> build/coverage/summary.txt
  make ci            sim + ip-test + synth
  make diagram       re-render docs/*.dot -> .svg / .png (Graphviz)
  make clean         remove build/ and ci/logs/
Simulation options (sim, wave, cov; NAME=value on the make command line):
  QUICK=1            skip the register dumps of sections 3 and 5 in the firmware report (GPIO0[31] strap): about 3 h faster; the set-up old / new value reports still run
  IDEAL_PLL=1        clock generator PLLs as ideal clock toggles at the exact ratios (faster; PLL lock behaviour not modelled)
  VCD=1              dump all signals to build/sim/video_processor_tb.vcd (large: use with a window)
  VCD_START_US=<n>   start the VCD dump at n us of simulated time (VCD=1 or make wave)
  VCD_STOP_US=<n>    stop the VCD dump at n us of simulated time (VCD=1 or make wave)
  GIF=<file>         tracking test input: any animated GIF (default tb/images/pedestrian_walk.gif); its size sets the frame size (fitted to 320 x 240)
  GIF_BW=1           convert a colour input GIF to black and white (BT.601 luma); without it a colour GIF runs through the pipeline in colour
  GIF_FRAMES=<n>     send only the first n frames of the tracking GIF (shorter run; default every frame)
Results (build/sim/): video_processor_tb.log, cpu_bootup.txt (UART 0 report), output_images/*.ppm,
  gif-input/<name>_<w>x<h>.gif (the sequence as sent, plus <name>_bw.gif when converted),
  gif-output/<name>_tracked.gif (HDMI output with the dashed tracking box)
Examples:
  make sim                                         full system test, default pedestrian GIF (long: every check, real PLL models)
  make sim QUICK=1 IDEAL_PLL=1                     fastest full run
  make sim QUICK=1 IDEAL_PLL=1 GIF_FRAMES=6        quick check of the tracking flow on the first 6 GIF frames
  make sim GIF=$HOME/clips/walk.gif                track in your own GIF (colour stays colour)
  make sim GIF=$HOME/clips/walk.gif GIF_BW=1       your own colour GIF, converted to black and white first
  make sim VCD=1 VCD_START_US=2000 VCD_STOP_US=2200    waveforms of a 200 us window only
  make wave QUICK=1 IDEAL_PLL=1 VCD_START_US=2000 VCD_STOP_US=2100    same, then open Surfer
  make cov QUICK=1                                 coverage of the quick run
  make sim GIF=../my_clips/street.gif GIF_FRAMES=20 QUICK=1    relative path (from this directory), first 20 frames
Without make: scripts/run_sim.sh [--quick] [--ideal-pll] [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>]
  [--gif=<file>] [--gif-bw] [--gif-frames=<n>] [--lint] [--list-tests]
```

## Tests

| Testbench | Test | Description |
|-----------|------|-------------|
| `video_processor_tb` | `test_boot` | py_soc boots the firmware (sw/video_proc.py) from the SPI flash model (boot_done, no boot error). |
| `video_processor_tb` | `test_core_reset` | the core logic (video) stays in reset while the CPU boots and tests its peripherals, and leaves it only when the CPU writes SYSCTL CORE_RESET after a clean initialisation (stage 3, no errors). |
| `video_processor_tb` | `test_firmware` | the firmware reaches stage 100 (video running) with no errors (its CPU peripheral self-test included), counted >= 6 isp_stats interrupts and switched the "running" LED (GPIO0[1]) on. |
| `video_processor_tb` | `test_vision_output` | vision_system's output (csi2_rx -> ISP bypassed: raw / 4 on R, G, B -> insert point -> vs_stream_adapter -> identity correction) is the camera image within 1 LSB (vision_system's own tolerance) and the same in every frame. |
| `video_processor_tb` | `test_hdmi` | the HDMI image (tmds_serializer lanes deserialised and decoded by hdmi_bfm) equals it exactly; no HDMI protocol error. |
| `video_processor_tb` | `test_lvds` | the LVDS link A image (VESA 24 bpp) equals it exactly. |
| `video_processor_tb` | `test_adapter` | vision_system processed frames and lost no corrected pixel (return FIFO). |
| `video_processor_tb` | `test_uart_report` | the UART 0 report (saved to cpu_bootup.txt) reaches "END OF REPORT" with no [FAIL] line and at least MIN_PASS [PASS] lines, and the firmware stage is 200. The frame event transcript ("  [<time> us] <event>" lines) is the true sequence: every line is the next marker frame_counter logged (channel, count and time, in the order the testbench saw the markers), counts run 1, 2, 3, ... per channel, times never go back, each frame's events come before its last-stage end; every image of the sequence is reported at all 5 points (section 7) and every GIF frame at the first stage, the tracker and the last stage (section 8). |
| `video_processor_tb` | `test_images` | 4 colour and 4 monochrome images, one frame each, paced so each image reaches vision_system (the next one starts once vision_system can take it, at least the camera's frame gap later; the camera sets the image format pin GPIO0[30] during the gap before each image; the firmware reprograms the ISP). Each image's frame at every module output it reached is saved as output_images/<module>_<c|m>_<n>_output.ppm. Checks: monochrome - the ISP output (isp_csc) is the input image exactly; colour - the demosaic keeps every native Bayer sample and the output is in colour; both - vision_system within 1 LSB of isp_csc, blur_sharpen equals conv2d_ref of vision_system, HDMI and LVDS equal blur_sharpen. Every image must pass the whole pipeline (none dropped by vs_stream_adapter). frame_counter: both counts 0 before the sequence (cleared by the firmware), then 8 at the first and 8 at the last stage. |
| `video_processor_tb` | `test_tracking` | pedestrian tracking: the input GIF (+GIF_IN, any animated GIF; default the pedestrian, 128 x 96, 50 frames) is read with gif_io at start-up; its size (fitted to 320 x 240) is the frame size the firmware reads from the camera (registers 0x30-0x33) and programs everywhere. A colour GIF is sent in colour (RGGB mosaic, ISP demosaic), or converted to black and white with +GIF_BW (also written as gif-input/<name>_bw.gif; the sequence as sent is written to gif-input/<name>_<w>x<h>.gif). Once the firmware has set every block to that size (stage 170) the camera sends each GIF frame (paced like the image test, GPIO0[29] high). Checks per frame: the object_tracker results equal track_ref's model of its input frame and window; the symbol_overlay output equals the model's drawing of the objects it applied; the HDMI image equals the overlay output. Tracking: the pedestrian is found in the first frame (whole-frame search) and from the second frame on object 0 is an enabled dashed rectangle containing the centre of the true figure (track_ref find_dark on the GIF frame) and, from the third, covering at least 75 % of it; the firmware counted every frame as found. (Quality is judged only on frames with a dark target, so any GIF can be used.) The HDMI frames are written as an animated GIF (+GIF_OUT, input frame times) and read back within 1 grey level. frame_counter counted every GIF frame. |

## Registers

- address map: the CPU address map in this README; each block's own register map:
  - [`py_soc`](../../ip/cpu/py_soc/docs/py_stream_port_regs.md)
  - [`py_soc`](../../ip/cpu/py_soc/docs/py_sysctl_regs.md)
  - [`video_pipeline`](../../ip/video/video_pipeline/docs/video_pipeline_regs.md)
  - [`uart`](../../ip/peripherals/uart/docs/uart_regs.md)
  - [`i2c_master`](../../ip/peripherals/i2c_master/docs/i2c_master_regs.md)
  - [`spi_master`](../../ip/peripherals/spi_master/docs/spi_master_regs.md)
  - [`gpio`](../../ip/peripherals/gpio/docs/gpio_regs.md)
  - [`intc`](../../ip/peripherals/intc/docs/intc_regs.md)
  - [`watchdog`](../../ip/timing/watchdog/docs/watchdog_regs.md)
  - [`spi_flash_ctrl`](../../ip/peripherals/spi_flash_ctrl/docs/spi_flash_ctrl_regs.md)
  - `scaler_ctrl`: in the header of [`scaler_ctrl.sv`](../../ip/scalers/scaler_ctrl/src/scaler_ctrl.sv)
  - `scaler_bilinear`: in the header of [`scaler_bilinear.sv`](../../ip/scalers/scaler_bilinear/src/scaler_bilinear.sv)
  - [`vision_system`](../vision_system/docs/vision_system_regs.md)
  - [`blur_sharpen`](../../ip/video/blur_sharpen/docs/blur_sharpen_regs.md)
  - [`frame_counter`](../../ip/video/frame_counter/docs/frame_counter_regs.md)
  - [`object_tracker`](../../ip/video/object_tracker/docs/object_tracker_regs.md)
  - [`symbol_overlay`](../../ip/video/symbol_overlay/docs/symbol_overlay_regs.md)

## Prompt

- [video_processor_prompt.md](docs/video_processor_prompt.md): the prompt that regenerates this block, reverse-engineered from its sources (`python3 ../../ip/scripts/make_ip_prompts.py --only video_processor`)
<!-- readme:end -->

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG.

### Data flow

[![Data flow of `video_processor`](docs/video_processor_dataflow.svg)](docs/video_processor_dataflow.svg)
<!-- diagrams:end -->
