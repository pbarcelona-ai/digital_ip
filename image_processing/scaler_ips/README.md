# Real-Time Image Scaler IP Family (SystemVerilog)

This repository contains seven stand-alone image-scaling IPs: nearest, bilinear, edge-directed, bicubic, Lanczos, trilinear and anisotropic. There is also a generic polyphase engine that can be used directly, a contrast-adaptive sharpening IP (`sharpen_cas`), and an FSR 1-style spatial upscaler (`spatial_upscaler` = Lanczos + sharpening). Every IP has:

* **AXI4-Lite** control registers,
* **AXI4-Stream** video in and out (`tuser` = start of frame, `tlast` = end of line),
* arbitrary input and output sizes up to `MAX_W × MAX_H`, with independent non-integer X/Y factors for both upscaling and downscaling,
* a self-checking testbench that compares every output pixel bit-exactly against an independent reference model, with AXI protocol checkers (procedural and SVA) and functional-coverage reports on every interface.

The method for deriving coefficients and registers for any scaling factor is in [`docs/coefficient_derivation.md`](docs/coefficient_derivation.md), and is implemented in [`tools/scaler_coefs.py`](tools/scaler_coefs.py).

## Directory layout

Every reusable module has its own directory with `src/` and `tb/` subdirectories.

| Directory | Kind | Contents |
|---|---|---|
| `scaler_nearest/` | IP | Point sampling (1×1) |
| `scaler_bilinear/` | IP | 2×2 bilinear, weights computed in hardware |
| `scaler_edge_directed/` | IP | 2×2 data-dependent triangulation (edge-aware bilinear) |
| `scaler_bicubic/` | IP | 4×4 polyphase, any Mitchell-Netravali (B,C) cubic |
| `scaler_lanczos/` | IP | 6×6 polyphase, Lanczos-3 (or Lanczos-2) |
| `scaler_trilinear/` | IP | Hardware mip pyramid plus trilinear sampling |
| `scaler_anisotropic/` | IP | Mip pyramid plus up to 16 trilinear probes per pixel |
| `scaler_polyphase/` | engine / IP | Generic separable polyphase scaler, TAPS = 2…16 (even) |
| `scaler_mip/` | engine / IP | Generic mip-map scaler (LEVELS, ANISO_MAX_LOG2) |
| `sharpen_cas/` | IP | Contrast-adaptive sharpening (FidelityFX CAS style), 3×3, line buffers |
| `spatial_upscaler/` | IP | FSR 1-style upscaler: `scaler_lanczos` → `sharpen_cas`, one AXI-Lite port |
| `axil_split/` | module | AXI4-Lite 1-to-2 address decoder |
| `scaler_ctrl/` | module | Common register map, AXI-Stream capture, frame sequencing |
| `axil_regbus/` | module | AXI4-Lite slave to simple register bus bridge |
| `scaler_dda/` | module | Output raster scan to 16.16 source-coordinate generator |
| `banked_framebuf/` | module | Frame store returning any T×T clamped window every clock |
| `axi_checkers/` | verification | `axis_checker` / `axil_checker`: protocol assertions (procedural + SVA) and functional coverage |
| `scaler_tb_lib/` | verification | Shared testbench kit, reference helpers, SV coefficient generator |
| `tools/` | scripts | `run_all.sh` (regression), `run_iverilog.sh` (calls `<dir>/run.sh`), `run_sim.sh` + `tb_args.sh` (Verilator); `scaler_coefs.py` (optional register/coefficient generator for driver software) |
| `docs/` | docs | Coefficient derivation |
| `images/` | data | Sample PPM (P6) input image |

Each directory also has a `run.sh` that builds and runs its testbench with Icarus Verilog in one command (results in `<dir>/sim_out/`). Each `tb/` directory contains `tb_<name>.sv` and `build.f`, the compile file list with every RTL dependency relative to `tb/`. The last block of every testbench dumps a VCD waveform (see [Waveforms](#waveforms)).

## Architecture

```
 s_axis ──► scaler_ctrl ──► banked_framebuf ──► window ──► kernel ──► m_axis
 (video)    capture FSM      (B×B RAM banks)    T×T        datapath   (video)
               ▲                    ▲
 s_axil ──► registers        scaler_dda (16.16 source coordinates, stall-able)
```

* **Frame-buffer architecture.** A frame is captured, then the output frame is generated at 1 pixel per clock (anisotropic: 1 per N probes). Latency is one input frame. The input is back-pressured (`tready = 0`) while an output frame is generated. Because of this, down- and upscaling by any ratio need no rate-matching FIFOs.
* **Conflict-free window reads.** The frame is spread over `B × B` banks, where `B` is the next power of two ≥ taps. Any `T × T` window, including clamped windows at the image edges, needs at most one read per bank, so one full window is available every clock.
* **Whole-pipeline stall.** Every pipeline stage advances on `adv = !m_tvalid || m_tready`, so the IPs are fully AXI-Stream compliant under arbitrary back-pressure.
* **Edge handling.** Clamp-to-edge (replicate) on all four sides.

### Memory sizing

On-chip storage is `MAX_W × MAX_H × CHANNELS × COMP_W` bits. The mip IPs add about one third more for the pyramid. For example, 640×480 RGB888 is 7.4 Mbit, which fits mid-range FPGA BRAM. 1920×1080 RGB888 is 50 Mbit, which needs UltraRAM or a replacement of `banked_framebuf` with an external-memory (DDR) frame store behind the same window interface.

## Common register map (all IPs)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x000 | CTRL | RW | [0] ENABLE: capture and scale frames continuously |
| 0x004 | STATUS | RO/W1C | [0] BUSY, [1] FRAME_DONE\*, [2] SOF_ERR\*, [3] EOL_ERR\*, [4] CAPTURING, [5] GENERATING (\* = write 1 to clear) |
| 0x008 | IN_SIZE | RW | [15:0] width, [31:16] height |
| 0x00C | OUT_SIZE | RW | [15:0] width, [31:16] height |
| 0x010 / 0x014 | STEP_X / STEP_Y | RW | unsigned 16.16 source pixels per output pixel |
| 0x018 / 0x01C | OFFS_X / OFFS_Y | RW | signed 16.16 source coordinate of output pixel 0 |
| 0x020 | FRAME_CNT | RO | frames completed |
| 0x024 | IP_ID | RO | ASCII tag: NEAR, BLIN, EDGE, BCUB, LANC, POLY, TRIL, ANIS, MIPM |
| 0x028 | CAPS | RO | [7:0] taps / levels, [15:8] channels, [23:16] component width, [31:24] phase bits |
| 0x02C | MAX_SIZE | RO | [15:0] MAX_W, [31:16] MAX_H |

`SOF_ERR` is set when data arrives before a start-of-frame (the data is dropped) or when a start-of-frame arrives mid-frame (capture restarts). `EOL_ERR` is set when `tlast` does not match `IN_SIZE`.

### IP-specific registers

| IP | Offset | Name | Description |
|---|---|---|---|
| edge_directed | 0x040 | THRESH | [15:0] diagonal decision threshold |
| edge_directed | 0x044 | EDGE_CTRL | [0] EDGE_EN (0 = pure bilinear) |
| bicubic / lanczos / polyphase | 0x040 | COEF_INFO | RO: taps, phase bits, COEF_W, COEF_FRAC |
| bicubic / lanczos / polyphase | 0x1000 + 4·(16·phase + tap) | COEF_H | signed coefficient, horizontal |
| bicubic / lanczos / polyphase | 0x2000 + 4·(16·phase + tap) | COEF_V | signed coefficient, vertical |
| trilinear / anisotropic | 0x040 | LOD | 8.8 level of detail |
| trilinear / anisotropic | 0x044 | ANISO_LOG2 | log2 of the probe count (clamped) |
| trilinear / anisotropic | 0x048 / 0x04C | PROBE_STEP_X/Y | signed 16.16 |
| trilinear / anisotropic | 0x050 / 0x054 | PROBE_START_X/Y | signed 16.16 |
| trilinear / anisotropic | 0x058 | MIP_INFO | RO: levels, max aniso, phase bits |
| trilinear / anisotropic | 0x060 + 4k | LEVEL_SIZE[k] | RO: size of mip level k |

### sharpen_cas registers

The sharpener does not resample, so it uses a reduced map with the same layout (ADDR_W = 8).

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x000 | CTRL | RW | [0] ENABLE, [1] BYPASS (pixels pass through unchanged) |
| 0x004 | STATUS | RO/W1C | [0] BUSY (frame in flight), [1] FRAME_DONE\*, [2] SOF_ERR\*, [3] EOL_ERR\* |
| 0x008 | SIZE | RW | [15:0] width, [31:16] height of the frames to process |
| 0x020 | FRAME_CNT | RO | frames completed |
| 0x024 | IP_ID | RO | "SHRP" |
| 0x028 | CAPS | RO | [7:0] 3 (kernel size), [15:8] channels, [23:16] component width |
| 0x02C | MAX_SIZE | RO | [15:0] MAX_W (line length; height is unlimited) |
| 0x040 | SHARPNESS | RW | 0–256 (values above 256 read back as 256); reset 128 |

SIZE, SHARPNESS and BYPASS are latched at each start of frame. Latency is about two lines, throughput is 1 pixel per clock, and the input is back-pressured only when all four line buffers are in use.

### spatial_upscaler register map (ADDR_W = 15)

| Offsets | Block | Contents |
|---|---|---|
| 0x0000 – 0x3FFF | `scaler_lanczos` | the complete scaler map: common registers, COEF_INFO, H table 0x1000, V table 0x2000 |
| 0x4000 – 0x40FF | `sharpen_cas` | the sharpener map above, offset by 0x4000 (CTRL 0x4000, SIZE 0x4008, SHARPNESS 0x4040, …) |

Program the sharpener `SIZE` to the scaler `OUT_SIZE` and enable it before enabling the scaler. `tools/scaler_coefs.py upscaler --in W H --out W H --sharpness S` emits the complete sequence.

## Parameters

| Parameter | Default | IPs | Meaning |
|---|---|---|---|
| CHANNELS, COMP_W | 3, 8 | all | Pixel = CHANNELS × COMP_W bits in `tdata` (component 0 in the LSBs) |
| MAX_W, MAX_H | 1920, 1080 | all | Frame buffer capacity |
| ADDR_W | 14 | all | AXI-Lite address width (≥ 14 for the coefficient tables) |
| PHASE_BITS | 8 (bilinear family), 6 (polyphase) | | Sub-pixel resolution |
| TAPS | 4 / 6 | polyphase | Kernel size, even, up to 16 |
| COEF_W, COEF_FRAC | 16, 14 | polyphase | Coefficient format (range ±2) |
| LEVELS | 4 (trilinear), 5 (aniso) | mip | Pyramid depth |
| ANISO_MAX_LOG2 | 0 / 4 | mip | Maximum probes = 2^N |
| MAX_W | 1920 | sharpen_cas | Longest line (4 line buffers of MAX_W pixels) |
| MAX_W, MAX_H, OUT_MAX_W | 1280, 720, 2560 | spatial_upscaler | Scaler frame buffer (input) and sharpener line length (output) |

## Quick start (software)

```bash
tools/scaler_coefs.py polyphase --kernel lanczos --a 3 --taps 6 \
    --in 1280 720 --out 1920 1080 --format c > cfg.h
```

This emits the full register sequence. Write each `{offset, value}` pair to the IP in order, then stream frames. See §7 of the derivation document. For the sharpener and the upscaler use `scaler_coefs.py sharpen --in W H --sharpness S` and `scaler_coefs.py upscaler --in W H --out W H --sharpness S` (§8–§9).

## Testbench command-line options (IP testbenches)

Every IP testbench (`scaler_nearest`, `scaler_bilinear`, `scaler_edge_directed`, `scaler_polyphase`, `scaler_bicubic`, `scaler_lanczos`, `scaler_mip`, `scaler_trilinear`, `scaler_anisotropic`, `sharpen_cas`, `spatial_upscaler`) accepts these run-time options. They are simulator plusargs, so they go after `vvp sim.vvp` or after the Verilator executable. The same options can be given to each directory's `run.sh` and to the helper scripts.

| Option | Default | Effect |
|---|---|---|
| `+IMG=<file.ppm>` | none | Use a binary PPM (P6) image as the input frame instead of the generated test patterns. Comments in the header and maxval 1–65535 are supported; samples are rescaled to `COMP_W` bits. |
| `+OUT_W=<n>`, `+OUT_H=<n>` | see below | Output size for an `+IMG` run. If only one is given, the other axis keeps the input size. |
| `+OUTDIR=<dir>` | `.` (`run.sh`: `<ip>/sim_out/`; `tools/run_sim.sh`: `ppm_out/<ip>/`) | Directory for the PPM files and, with `run.sh`, the VCD. The simulator cannot create directories, but the scripts do. |
| `+NO_PPM` | off | Do not write any PPM files. |
| `+TIMEOUT_MS=<n>` | 200 | Watchdog, in milliseconds of simulated time. Raise it for very large images. |
| `+VCD=<file>` | `tb_<ip>.vcd` (`run.sh`: `<OUTDIR>/tb_<ip>.vcd`) | Waveform dump file. Also accepted by the module testbenches. |
| `+NO_VCD` | off | Do not dump waveforms. Also accepted by the module testbenches. |
| `+SHARP=<0..256>` | 128 | `sharpen_cas` and `spatial_upscaler` only: SHARPNESS for `+IMG` runs. |

`sharpen_cas` keeps the image size, so `+OUT_W`/`+OUT_H` do not apply and an `+IMG` run processes the image once. For `spatial_upscaler` the output may be at most twice the input size in each direction (the reference model's buffer limit).

**Without `+IMG`**, the testbench generates its own input images (noise, diagonal edges, checkerboard and flat patterns) and runs the full self-checking suite described below.

**With `+IMG`**, the file is scaled and every output pixel is still checked bit-exactly against the reference model. If `+OUT_W`/`+OUT_H` are given, one test runs at that size. Otherwise three tests run: a 1.5× upscale, a 0.4× downscale, and an anamorphic squeeze to ¼ height (which is where the anisotropic IP differs from trilinear).

**Output files.** For every test, the testbench writes P6 files:

```
<OUTDIR>/<ip>_t<NN>_in_<W>x<H>.ppm    generated input image (not written for +IMG runs)
<OUTDIR>/<ip>_t<NN>_out_<W>x<H>.ppm   output image exactly as received from m_axis
```

`NN` is the test number printed in the log. Component 0 (the `tdata` LSBs) is written as red, component 1 as green and component 2 as blue. PPM I/O requires `CHANNELS = 3`; with `COMP_W > 8` the files use 16-bit samples.

**Image size limit.** The testbench frame buffer, and therefore the DUT's `MAX_W`/`MAX_H`, is fixed at compile time by the defines `TB_MAX_W` and `TB_MAX_H` (default 48 × 40). The helper scripts read the PPM header and set these automatically. When compiling by hand, pass the defines yourself; the testbench stops with a clear message if the image does not fit.

```bash
# run.sh / scripts: the defines and output directories are handled for you
scaler_lanczos/run.sh +IMG=photo.ppm                        # 3 default sizes
scaler_lanczos/run.sh +IMG=photo.ppm +OUT_W=1280 +OUT_H=720
scaler_bicubic/run.sh +NO_PPM +NO_VCD                       # generated suite, no files
tools/run_sim.sh scaler_anisotropic +IMG=photo.ppm +OUT_H=90 +OUTDIR=results   # Verilator
tools/run_all.sh +IMG=photo.ppm                             # every IP on one image

# By hand (Icarus), for a 640x480 image
cd scaler_bicubic/tb
iverilog -g2012 -DTB_MAX_W=640 -DTB_MAX_H=480 -I ../../scaler_tb_lib/src \
         -s tb_scaler_bicubic -o sim.vvp -f build.f
vvp -n sim.vvp +IMG=/path/photo.ppm +OUT_W=960 +OUT_H=720 +OUTDIR=/tmp

# By hand (Verilator)
verilator --binary --timing --trace -Wno-fatal +define+TB_MAX_W=640 +define+TB_MAX_H=480 \
          -I../../scaler_tb_lib/src --top-module tb_scaler_bicubic -F build.f
obj_dir/Vtb_scaler_bicubic +IMG=/path/photo.ppm
```

A sample input is included: `images/test_96x72.ppm` (for example, `tools/run_all.sh +IMG=images/test_96x72.ppm`).

Simulation time grows with image area. A 96 × 72 image takes 1–30 s per IP on Icarus; a 640 × 480 image takes minutes on Icarus and is much faster on Verilator. To make a P6 file from any image, use `convert in.png out.ppm` (ImageMagick) or `pnmtopng`/`pngtopnm` (netpbm); most image viewers open the results directly.

## Waveforms

The last block of every testbench (all 17, modules included) dumps a VCD of the complete testbench and DUT hierarchy:

```systemverilog
initial begin : vcd_dump
  string vcd_file;
  if (!$test$plusargs("NO_VCD")) begin
    if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_<name>.vcd";
    $dumpfile(vcd_file);
    $dumpvars(0, tb_<name>);
  end
end
```

| How you run | VCD location |
|---|---|
| `<dir>/run.sh` | `<dir>/sim_out/tb_<dir>.vcd`, or `<OUTDIR>/…` with `+OUTDIR`, or any path with `+VCD=<file>` |
| `tools/run_sim.sh <dir>` (Verilator, compiled with `--trace`) | `build/<dir>/tb_<dir>.vcd` |
| manual `vvp` | `tb_<dir>.vcd` in the working directory, unless `+VCD=` is given |
| `tools/run_all.sh` | disabled (`+NO_VCD`) for speed; set `VCD=1` to keep them |

With the generated test suites, files are about 1–30 MB (the polyphase testbench is the largest). `+IMG` runs with large images produce correspondingly larger files; use `+NO_VCD` when you only need the images. View with any VCD viewer, e.g. `gtkwave scaler_bicubic/sim_out/tb_scaler_bicubic.vcd`. Useful signals: `dut.m_axis_*` and `s_axis_*` for the streams, `dut.u_ctrl.state` for frame sequencing, and `dut.u_dda.o_x`/`o_y` for the source coordinates (in `scaler_bicubic`, `scaler_lanczos`, `scaler_trilinear` and `scaler_anisotropic` the core sits one level deeper, under `dut.u_core`; in `spatial_upscaler` the stages are `dut.u_scaler` and `dut.u_sharpen`, and the stream between them is `dut.mid_t*`).

## Protocol checkers and functional coverage

`axi_checkers/` provides two passive checkers. Every testbench instantiates them automatically through `scaler_tb_lib`: one on the AXI-Lite link, one on the input stream and one on the output stream. Any violation makes the test fail.

| Checker | Rules |
|---|---|
| `axis_checker` | `AXIS_HOLD`: tvalid never retracted before the handshake. `AXIS_STABLE`: tdata/tuser/tlast stable while stalled. `AXIS_X_VALID`, `AXIS_X_PAYLOAD`: no X/Z. Output streams also get the framing rules: `AXIS_SOF` (tuser exactly on the first beat of a frame), `AXIS_EOL` (tlast exactly at column W−1) and `AXIS_FRAME` (no new frame before W×H beats). |
| `axil_checker` | `AXIL_HOLD_*`, `AXIL_STABLE_*` on AW, W, AR (master side) and B, R (slave side). `AXIL_X`. `AXIL_BRESP_EARLY` (B before both AW and W were accepted). `AXIL_RRESP_EARLY`. `AXIL_RESP` (non-OKAY). `AXIL_OUTSTANDING`. |

**Two implementations.** Each rule exists twice. The procedural version always runs, on every simulator including Icarus Verilog. The SVA version (`assert property` / `cover property`) is compiled when `SVA_ON` is defined. `tools/run_sim.sh` builds Verilator with `--assert +define+SVA_ON`, so there both versions check every cycle. For a commercial simulator, add `+define+SVA_ON`. Icarus does not support concurrent assertions, which is why the procedural form exists.

**Checker self-test.** The `axi_checkers` testbench first drives legal traffic with random stalls, where zero errors are expected. It then breaks each rule on purpose, and every violation must be detected by both implementations.

**Coverage report.** At the end of each run the testbench prints `COVERAGE` lines before the verdict:

```
COVERAGE s_axil     writes=90 reads=56 aw_first=31 w_first=30 aw_with_w=29 ... bins 9/11  assertion_errors=0 sva_errors=0
COVERAGE s_axis     beats=6196 ... stall_len[1|2-3|4-15|16+]=0|0|0|2  bins 7/10  assertion_errors=0 sva_errors=0
COVERAGE m_axis     beats=5789 frames=9 ... stall_len[1|2-3|4-15|16+]=940|367|30|0  bins 10/10 ...
COVERAGE features   x_up=4 x_down=4 x_same=2 ... non_integer=5 down>=4x=2
COVERAGE features   in_1px=1 out_1px=1 in_max=2 junk_sof=1 multi_frame=1 full_rate=1 ... bins 21/21
```

* **Stream coverage:** beats, frames, SOF/EOL beats, back-to-back transfers, handshakes after a stall and ready-before-valid, idle cycles, stall cycles and the longest stall, and a stall-length histogram.
* **AXI-Lite coverage:** reads and writes, AW-first / W-first / simultaneous ordering, waits on AW/AR, stalled B/R responses, and back-to-back accesses.
* **Feature coverage:** the scaling scenarios exercised (up, down and same per axis, mixed, exact 2×, non-integer, ≥ 4× down, 1-pixel input and output, maximum size, junk before SOF, multi-frame, full rate versus back-pressure, image file, and each test pattern).

The testbench AXI-Lite master randomises AW/W order and BREADY/RREADY delays to reach the ordering and stall bins. Bins that only the DUT can produce stay at 0 where the design never creates the condition, and this is expected. For example, `aw_wait`/`ar_wait` stay at 0 because the register slaves are always ready. On the scalers' input streams, `stall_len[1]` stays at 0 because a frame-buffer scaler only drops `tready` for a whole generation phase, which shows up in the ≥ 16 bucket. `sharpen_cas` exercises all input-stall buckets because its line buffers apply real back-pressure.

## Verification

No Python is needed to simulate. Coefficient tables are generated inside the testbench by `scaler_tb_lib/src/scaler_coef_gen.svh`, which is bit-identical to the Python tool. Python is only used by the optional software helper `tools/scaler_coefs.py`.

Supported simulators: **Icarus Verilog 12** (`-g2012`) and **Verilator 5.x** (`--timing`). The code is standard SystemVerilog and should also run on commercial simulators.

```bash
scaler_lanczos/run.sh                          # one testbench, Icarus (any directory has run.sh)
tools/run_sim.sh scaler_lanczos                # one testbench, Verilator
tools/run_all.sh                               # full regression, Icarus (about 1 minute)
SIM=verilator tools/run_all.sh                 # full regression, Verilator
VCD=1 tools/run_all.sh                         # regression with waveform dumps
```

To compile manually without any scripts:

```bash
cd scaler_bicubic/tb
iverilog -g2012 -I ../../scaler_tb_lib/src -s tb_scaler_bicubic -o sim.vvp -f build.f && vvp -n sim.vvp
```

Each IP testbench runs a standard suite plus IP-specific tests:

* identity, non-integer upscale, strong downscale, mixed down-X / up-Y, exact 2×, 1×1 source, 1×1 output, and maximum-size frames,
* random input `tvalid` gaps and output `tready` back-pressure, plus a full-rate run,
* junk before start-of-frame (must be dropped and flagged), `tuser`/`tlast` placement on the output, and no extra beats,
* register read-back, ID/CAPS, FRAME_DONE and FRAME_CNT, and return to idle,
* every generated input and every output written as a PPM image for visual inspection (identity tests produce byte-identical input and output files).

The IP-specific tests cover several cubic kernels, CAS sharpness extremes, BYPASS and SHARPNESS clamping, single-row and single-column frames, heavy output back-pressure on the line-buffer design, the two-stage upscaler model at up to 2× in each axis, Lanczos overshoot clamping, 8-tap anti-aliased downscales, edge-direction coverage (all three modes hit), equivalence with bilinear when `EDGE_EN = 0`, LOD beyond the top level, fractional LOD, 1:8 and 16:1 anisotropy, and probe-count clamping.

Regression results. Every testbench passes on both Icarus Verilog 12.0 and Verilator 5.020; check counts are from Icarus, and a few differ slightly between simulators because the random sequences differ.

| Testbench | Result |
|---|---|
| axi_checkers | PASS, legal traffic clean and every rule violation detected (procedural; plus SVA on Verilator) |
| axil_regbus | PASS, 2,067 checks (random AW/W order, stalled responses) |
| axil_split | PASS, 600 random accesses to two slaves, 305 checks |
| scaler_ctrl | PASS, 6 capture scenarios, 963 checks |
| banked_framebuf | PASS, TAPS = 1, 2, 3, 4, 6, 8; 466,669 tap checks |
| scaler_dda | PASS, 42 random configs, 13,402 checks |
| scaler_nearest | PASS, 10 tests |
| scaler_bilinear | PASS, 10 tests |
| scaler_edge_directed | PASS, 13 tests |
| scaler_polyphase (8 taps) | PASS, 12 tests |
| scaler_bicubic | PASS, 14 tests |
| scaler_lanczos | PASS, 12 tests |
| scaler_mip (3 levels, 4 probes) | PASS, 18 tests |
| scaler_trilinear | PASS, 14 tests |
| scaler_anisotropic | PASS, 18 tests |
| sharpen_cas | PASS, 16 tests, 7,800 checks |
| spatial_upscaler | PASS, 13 tests, 16,571 checks |

All runs finish with zero protocol-assertion errors (and zero SVA errors on Verilator).

The testbenches were also checked for sensitivity with deliberately injected RTL bugs: a rounding change, a mip averaging change, a CAS headroom change, and a line-buffer hazard (letting `sharpen_cas` overwrite a line one row too early). All were caught with hundreds to thousands of mismatches.

## Scope notes and limitations

* **Temporal and AI upscalers** (TAAU, FSR 2/3, DLSS, XeSS) are not included. They need motion vectors, depth, frame history and, for AI upscalers, trained network weights supplied by a renderer, so they cannot be self-contained video scalers. `spatial_upscaler` provides the spatial FSR 1-style equivalent (Lanczos plus contrast-adaptive sharpening). It uses Lanczos-3 rather than FSR's edge-adaptive EASU kernel.
* **Classic pixel-art filters** (hqx, xBR) only work at fixed integer factors. `scaler_edge_directed` provides edge-aware interpolation at arbitrary factors instead.
* **Frame latency.** The frame-buffer scalers add one frame of latency (`sharpen_cas` adds only about two lines). A line-buffer or ping-pong variant would reduce latency but needs rate matching for downscaling.
* **Timing closure.** Kernel datapaths are written for clarity, with one combinational MAC tree per stage. For high clock rates, add pipeline registers inside the vertical and horizontal sums; the stall logic is unaffected.
* **Coefficient tables** have a bilinear default through `initial` blocks, which suits FPGA flows. ASIC flows must program the tables before enabling the IP.
* **CAS normalisation.** `sharpen_cas` replaces CAS's per-pixel divide with an equivalent-strength unsharp mask. It is exact at the minimum and maximum adaptive amount and monotonic in between (derivation §8).
* **Simulator notes.** The RTL has no `timescale` directive (only the checker files do); Verilator reports TIMESCALEMOD warnings, which are harmless. Icarus prints `sorry: constant selects in always_* processes`, an informational note about sensitivity lists that does not affect results.
