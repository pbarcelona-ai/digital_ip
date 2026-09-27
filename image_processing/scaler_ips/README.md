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
| `tools/` | scripts | `run_all.sh` (regression), `run_iverilog.sh` (calls `<dir>/run.sh`), `run_sim.sh` + `tb_args.sh` (Verilator), `synth_all.sh` and `gatesim.sh` (synthesis), `yosys/` (shared Yosys script, utilization report formatter); `scaler_coefs.py` (optional register/coefficient generator for driver software) |
| `docs/` | docs | Coefficient derivation |
| `images/` | data | Sample PPM (P6) input image |

Each directory also has a `run.sh` that builds and runs its testbench with Icarus Verilog in one command (results in `<dir>/sim_out/`). Each synthesizable directory also has a `synth.sh` and a `src/build.f` for Yosys synthesis (results in `<dir>/yosys/`, see [Synthesis](#synthesis-yosys-xilinx)). Each `tb/` directory contains `tb_<name>.sv` and `build.f`, the compile file list with every RTL dependency relative to `tb/`. The last block of every testbench dumps a VCD waveform (see [Waveforms](#waveforms)).

## Architecture

```
 s_axis ──► scaler_ctrl ──► banked_framebuf ──► window ──► kernel ──► m_axis
 (video)    capture FSM      (B×B RAM banks)    T×T        datapath   (video)
               ▲                    ▲
 s_axil ──► registers        scaler_dda (16.16 source coordinates, stall-able)
```

* **Three frame-store modes** (see [Buffering modes](#buffering-modes)): a single frame buffer (default), a double "ping-pong" frame buffer, and a line buffer. Output is generated at 1 pixel per clock in every mode (anisotropic: 1 per N probes). Rate matching for any up/down ratio comes from AXI-Stream back-pressure, so no rate-matching FIFOs are needed.
* **Conflict-free window reads.** The frame is spread over `B × B` banks, where `B` is the next power of two ≥ taps. Any `T × T` window, including clamped windows at the image edges, needs at most one read per bank, so one full window is available every clock.
* **DSP-friendly pipelines.** The bilinear, edge-directed, polyphase, mip and sharpening datapaths are pipelined with one multiply or one adder level per stage and exact bit widths, and the frame buffer's write port is registered. Results are bit-identical to the unpipelined arithmetic (the reference models did not change). Only the latency from input to output grows by a few cycles.
* **Whole-pipeline stall.** Every pipeline stage advances on `adv = !m_tvalid || m_tready`, so the IPs are fully AXI-Stream compliant under arbitrary back-pressure.
* **Edge handling.** Clamp-to-edge (replicate) on all four sides.

### Buffering modes

Every window-based IP (`scaler_nearest`, `scaler_bilinear`, `scaler_edge_directed`, `scaler_polyphase`, `scaler_bicubic`, `scaler_lanczos`, and the scaler stage of `spatial_upscaler`) has two compile-time parameters, `PINGPONG` and `LINE_BUF`. The mip-based IPs (`scaler_mip`, `scaler_trilinear`, `scaler_anisotropic`) have `PINGPONG` only. All modes use the same register map, coefficient tables and output, so software does not change.

| Mode | Parameters | Frame store | Input stalls… | Latency (input to first output pixel) | Throughput |
|---|---|---|---|---|---|
| Frame buffer (default) | `PINGPONG=0, LINE_BUF=0` | 1 frame | while every output frame is generated | one input frame | one frame at a time: capture time + output time |
| Ping-pong | `PINGPONG=1` | 2 frames | only when both buffers are busy | one input frame | capture of frame N+1 overlaps output of frame N |
| Line buffer | `LINE_BUF=1` | ring of `LB_ROWS` lines | when the ring is full or the output is slower | a few input lines | capture and output overlap within the frame |

**Ping-pong.** Frame A is captured into buffer 0 and handed to the generator. Frame B is then captured into buffer 1 while A is still being output. A third frame waits (input back-pressured) until A's output finishes, and then lands in buffer 0. For the mip IPs the whole pyramid is double-buffered: level 0 is written by the capture and the higher levels are built inside the buffer being generated.

**Line buffer.** The frame store becomes a ring of `LB_ROWS` lines (`LB_ROWS` = next power of two ≥ `taps + 2`, minimum 4: 4 lines for nearest, bilinear and edge-directed, 8 for bicubic and Lanczos (4–6 taps), 16 for 8-tap polyphase). Output generation starts with the first input pixel of the frame, and `scaler_ctrl` applies row-level flow control in both directions:

* the output scan (DDA) is held until every source row of the next output pixel's window has been fully received;
* input row *r* is accepted only while *r* < (lowest row still needed by any pixel in flight) + `LB_ROWS`, so a row is never overwritten before its last read.

Vertical upscaling therefore back-pressures the input (each input row feeds several output rows), and vertical downscaling back-pressures the output scan. The testbench measures the result directly: with 48×40 frames, the first output pixel appears after at most 4 input rows (nearest), about 11 for the Lanczos + sharpener chain, versus 40 for a frame buffer. Restrictions: `STEP_Y ≥ 0` (no vertical mirroring), and `MAX_H` no longer limits the image height.

### Memory sizing

On-chip storage by mode, for RGB888 (24-bit pixels):

| Mode | Storage | 640×480 | 1280×720 | 1920×1080 |
|---|---|---|---|---|
| Frame buffer | `MAX_W × MAX_H` pixels | 7.4 Mbit | 22.1 Mbit | 49.8 Mbit |
| Ping-pong | `2 × MAX_W × MAX_H` pixels | 14.7 Mbit | 44.2 Mbit | 99.5 Mbit |
| Line buffer, 4 lines (nearest, bilinear, edge-directed) | `4 × MAX_W` pixels | 61 kbit | 123 kbit | 184 kbit |
| Line buffer, 8 lines (bicubic, Lanczos-3) | `8 × MAX_W` pixels | 123 kbit | 246 kbit | 369 kbit |

The mip IPs add about one third more for the pyramid (twice that with ping-pong). A 640×480 frame buffer fits mid-range FPGA block RAM. A 1080p frame buffer needs UltraRAM-class memory or an external (DDR) frame store behind the same window interface. The **line-buffer mode brings 1080p down to about 0.4 Mbit**, which fits on essentially any FPGA. For Lanczos-3 it is split into 64 banks of 240 × 24 bits (8 × 8 banks, one 8-line ring), sizes that map well onto distributed/LUT RAM or small block RAMs. That configuration has been simulated end to end with a real 1920×1080 frame (see [Verification](#verification)).

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
| MAX_W, MAX_H | 1920, 1080 | all | Frame buffer capacity (line-buffer mode: MAX_W only) |
| PINGPONG | 0 | all scalers | 1 = double frame buffer (capture during output) |
| LINE_BUF | 0 | all except mip IPs | 1 = line buffer (latency of a few lines) |
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

## Synthesis (Yosys, Xilinx)

Every synthesizable directory has a `synth.sh` that runs an open-source Xilinx synthesis flow and writes all results to `<dir>/yosys/`. The verification-only directories (`axi_checkers`, `scaler_tb_lib`) have none.

**Requirements:** Yosys ≥ 0.33 (`apt install yosys`) and [sv2v](https://github.com/zachjs/sv2v) (a single static binary from its releases page). Yosys's built-in SystemVerilog reader supports only a subset of SystemVerilog, and it rejects constructs used in this RTL such as size casts (`32'(x)`) and initialised variables inside functions. sv2v converts the sources to Verilog-2005 first; the converted file is kept as `yosys/<top>.sv2v.v`.

**Flow**

```
src/build.f ──► sv2v ──► yosys -c tools/yosys/synth_xilinx.tcl ──► util_hier.awk
(RTL list)      (SV→V)    read · elaborate · compile · DSP · optimize ·    (hierarchical
                          memory→BRAM/LUTRAM · LUT/carry/FF map · check      utilization)
```

* `src/build.f`: the synthesis file list, dependencies first, with paths relative to `src/`. It is separate from `tb/build.f`, which adds the testbench and checkers.
* `tools/yosys/synth_xilinx.tcl`: the **one shared Yosys script**. It reads the Xilinx cell library and the design, elaborates with the requested parameters, then runs the labelled `synth_xilinx` stages one at a time, so each appears as its own section in the log: compile (generic optimisation, FSM extraction, width reduction), **DSP48 packing** (multipliers with pre-adders and accumulators), coarse optimisation, **memory mapping to block RAM, then LUT RAM, then flip-flops**, LUT/carry-chain/flip-flop mapping, and final checks. The hierarchy is kept (no flattening) so utilization can be reported per module, and I/O buffers are not inserted (out-of-context IP synthesis).
* `tools/yosys/util_hier.awk`: turns Yosys's per-module statistics into a **hierarchical utilization table**. Each instance of the design tree gets its totals (including everything below it) plus a `(self)` row for its own logic.

**Usage**

```bash
scaler_lanczos/synth.sh                                   # defaults (640x480 frame buffer)
scaler_lanczos/synth.sh -p LINE_BUF=1 -p MAX_W=1920       # 1080p line-buffer build
scaler_lanczos/synth.sh -family xcup -flags "-abc9"       # UltraScale+, ABC9 mapping
scaler_lanczos/synth.sh --help
tools/synth_all.sh                                        # every module, summary table
tools/synth_all.sh scaler_bicubic scaler_lanczos -- -p PINGPONG=1
```

| Option | Effect |
|---|---|
| `-p NAME=VALUE` | Override a top-level parameter (repeatable). Frame-buffer IPs default to `MAX_W=640 MAX_H=480` |
| `-family F` | `synth_xilinx` family: `xc7` (default), `xcu`, `xcup`, … |
| `-flags "…"` | Extra `synth_xilinx` options, e.g. `-nodsp`, `-nobram`, `-abc9` |
| `-iopad` | Insert I/O and clock buffers (default: out-of-context) |
| `-json` | Also write the netlist as JSON (large) |
| `SYN_DSP_PACK=1` (environment) | Let Yosys pack registers/adders into the DSP48s (`xilinx_dsp`); see *Flow settings* below before using it |
| `SYN_SRL=1` (environment) | Allow SRL16E/SRLC32E shift-register inference; see *Flow settings* below |

**Outputs in `<dir>/yosys/`:** `utilization_hier.rpt` (hierarchical table, also printed), `utilization.rpt` (raw `stat -tech xilinx` per module), `timing.rpt` (rough path-delay indicator, see below), `synth.log` (complete log), `<top>.sv2v.v` (converted source), `<top>_netlist.v` and `<top>.edf` (mapped netlist, e.g. for Vivado import).

**Flow settings chosen for correctness.** Three settings in `synth_xilinx.tcl` differ from a plain `synth_xilinx` run. Each one exists because gate-level simulation (below) showed Yosys 0.33 producing a netlist that does not match the RTL:

| Setting | Default | What it avoids | Re-enable with |
|---|---|---|---|
| no shift-register inference (`-nosrl`) | on | `xilinx_srl` turned an *enabled* delay line in `sharpen_cas` into SRL16Es with the clock enable tied high, corrupting data whenever the output stalls | `SYN_SRL=1` |
| DSP48 mapping without `xilinx_dsp` packing | on | `xilinx_dsp` register/adder/cascade packing produced a netlist that is not equivalent to the pipelined bicubic filter; this was confirmed with both Xilinx's and Yosys's DSP48E1 models. Every multiplier is still one DSP48; only the surrounding pipeline registers and adders stay in the fabric | `SYN_DSP_PACK=1` |
| explicit `pmux2shiftx` | on | `-nosrl` also skips this pass in Yosys 0.33, which doubled the LUTs of the frame buffers' tap multiplexers | (automatic) |

Re-enable the first two only with a Yosys version whose netlists pass `tools/gatesim.sh`. Two further issues were fixed at the source: sv2v 0.0.12 dropped the signedness of a size cast applied to an element of a 2-D signed array (an explicit `$signed()` in `sharpen_cas`), and `hierarchy -chparam` hits an internal assertion for some tops (the script uses the equivalent `chparam -set`).

Example (`scaler_lanczos/yosys/utilization_hier.rpt`, 640×480):

```
Instance                                            LUT   LUTRAM       FF    CARRY     MUXF   BRAM36      DSP
-------------------------------------------------------------------------------------------------------------
scaler_lanczos                                    28235      252    15830     1352     4709    256.0      135
  (self)                                              0        0        0        0        0      0.0        0
  scaler_polyphase                                28235      252    15830     1352     4709    256.0      135
    (self)                                        13263      252    14666      892       72      0.0      126
    banked_framebuf                               14464        0      484      401     4608    256.0        9
    scaler_ctrl                                     314        0      515       27       17      0.0        0
      (self)                                        303        0      361       27       17      0.0        0
      axil_regbus                                    11        0      154        0        0      0.0        0
    scaler_dda                                      194        0      165       32       12      0.0        0
```

**Results** (Yosys 0.33, sv2v 0.0.12, xc7, `tools/synth_all.sh` defaults: `-nosrl`, DSP mapping without packing; see the tool-issues table above):

| Module | Parameters | LUT | LUT RAM | FF | CARRY4 | BRAM36 | DSP48E1 | Time (s) |
|---|---|---|---|---|---|---|---|---|
| axil_regbus | (defaults) | 11 | 0 | 160 | 0 | 0 | 0 | 7 |
| axil_split | (defaults) | 76 | 0 | 117 | 0 | 0 | 0 | 7 |
| scaler_dda | (defaults) | 195 | 0 | 165 | 32 | 0 | 0 | 6 |
| scaler_ctrl | (defaults) | 313 | 0 | 515 | 27 | 0 | 0 | 9 |
| banked_framebuf | 640×480, 4 taps | 2,944 | 0 | 220 | 171 | 240 | 5 | 33 |
| scaler_nearest | 640×480 | 1,364 | 0 | 827 | 99 | 225 | 2 | 24 |
| scaler_bilinear | 640×480 | 2,080 | 0 | 1,528 | 206 | 228 | 21 | 28 |
| scaler_edge_directed | 640×480 | 2,481 | 0 | 1,919 | 284 | 228 | 19 | 31 |
| scaler_polyphase (4 taps) | 640×480 | 7,964 | 120 | 8,754 | 649 | 240 | 65 | 132 |
| scaler_bicubic | 640×480 | 7,966 | 120 | 8,754 | 649 | 240 | 65 | 132 |
| scaler_lanczos | 640×480 | 28,235 | 252 | 15,830 | 1,352 | 256 | 135 | 203 |
| scaler_mip | 640×480 | 5,952 | 0 | 3,128 | 634 | 310 | 51 | 29 |
| scaler_trilinear | 640×480 | 5,975 | 0 | 3,128 | 634 | 310 | 51 | 29 |
| scaler_anisotropic | 640×480 | 7,094 | 0 | 3,206 | 717 | 312 | 51 | 33 |
| sharpen_cas | 1920 wide (defaults) | 2,192 | 0 | 1,590 | 226 | 6 | 9 | 21 |
| spatial_upscaler | 640×480 | 31,116 | 252 | 17,541 | 1,578 | 264 | 144 | 227 |

How to read these numbers:

* They are Yosys estimates before place and route. With the correctness settings above, the pipeline registers and adders around each multiplier stay in the fabric (the FF and CARRY4 columns). Vivado would absorb many of them into the DSP48s (AREG/BREG/MREG/PREG, post-adders, cascades) and typically ends noticeably lower.
* The DSP count equals the multiplier count exactly: bicubic 3 colours × (4×4 vertical + 4 horizontal) = 60, plus 5 in its frame buffer's address arithmetic; Lanczos 3 × (6×6 + 6) = 126, plus 9. The polyphase coefficient tables land in LUT RAM (RAM64M), the frame and line buffers in RAMB36/RAMB18.
* A 640×480×24-bit frame is 7.4 Mbit, which is 225 RAMB36 for nearest (one bank, near-ideal packing). The multi-bank window buffers of the 4- and 6-tap IPs round each bank up, reaching 240–256.
* Lanczos is the largest IP. About half of its LUTs are the frame buffer's 6×6 tap multiplexer (each of 36 taps selects one of 64 banks); the rest is mostly the filter's fabric adders.

**Pipelined datapaths.** The filter datapaths of `scaler_bilinear`, `scaler_edge_directed`, `scaler_polyphase` (and so bicubic and Lanczos), `scaler_mip` and `sharpen_cas` are pipelined with at most one multiply or one add per stage and exact operand widths, and the frame buffer's write port is registered. These changes are transparent to the interfaces (AXI-Stream back-pressure stalls the whole pipeline, as before). They are verified bit-exact by the full regression in all buffering modes on Icarus, by the frame-mode regression on Verilator, and at gate level.

**Timing indicator.** `timing.rpt` is Yosys's `sta` on the flattened netlist, with cell delays only. Routing is ignored, carry chains and MUXF7/F8 have no timing arcs in the Yosys 0.33 library, and there are no clock constraints, so the longest reported path can begin at the asynchronous reset. Treat it as a rough indicator for spotting deep logic, not as an Fmax; use Vivado with the `.edf` netlist for real timing.

**Gate-level check of the flow.** `tools/gatesim.sh <module>` synthesizes the module at the testbench's configuration with the same shared script, then runs the module's **unchanged self-checking testbench on the mapped Xilinx netlist** with Icarus Verilog. Yosys's `cells_sim.v` models LUTs, flip-flops, carry chains, MUXF and LUT RAM functionally, but its `RAMB18E1`/`RAMB36E1` are timing-only stubs whose outputs are X. The script therefore uses Xilinx's functional UNISIM models for the block RAMs and the DSP48E1 (Apache-2.0, [github.com/Xilinx/XilinxUnisimLibrary](https://github.com/Xilinx/XilinxUnisimLibrary), downloaded on first use into `tools/yosys/unisim/`), so the netlist is simulated exactly as mapped, block RAMs included. `+QUICK` selects a short representative suite for large netlists; `-vcd` dumps a gate-level VCD and opens it in Surfer.

| Module | Gate-level result (final flow) |
|---|---|
| scaler_nearest | PASS, full suite (10 tests, 6,462 checks), block RAM netlist |
| scaler_bilinear | PASS, full suite (10 tests, 6,462 checks) |
| scaler_edge_directed | PASS, full suite (13 tests, 11,497 checks) |
| sharpen_cas | PASS, full suite (16 tests, 7,800 checks) |
| scaler_bicubic | PASS, `+QUICK` (3 tests, 1,862 checks), 60 DSP48E1 |
| scaler_mip, scaler_trilinear, scaler_anisotropic | PASS, `+QUICK` |
| scaler_polyphase (8 taps), scaler_lanczos, spatial_upscaler | not run: compiling their gate-level netlists exceeds the 4 GB of the machine used here (Icarus is killed). The polyphase engine they use is covered through `scaler_bicubic` |

Along the way this check found the three Yosys/sv2v issues listed above, none of which RTL simulation can detect.

## Testbench command-line options (IP testbenches)

Every IP testbench (`scaler_nearest`, `scaler_bilinear`, `scaler_edge_directed`, `scaler_polyphase`, `scaler_bicubic`, `scaler_lanczos`, `scaler_mip`, `scaler_trilinear`, `scaler_anisotropic`, `sharpen_cas`, `spatial_upscaler`) accepts these run-time options. They are simulator plusargs, so they go after `vvp sim.vvp` or after the Verilator executable. The same options can be given to each directory's `run.sh` and to the helper scripts.

| Option | Default | Effect |
|---|---|---|
| `+IMG=<file.ppm>` | none | Use a binary PPM (P6) image as the input frame instead of the generated test patterns. Comments in the header and maxval 1–65535 are supported; samples are rescaled to `COMP_W` bits. |
| `+OUT_W=<n>`, `+OUT_H=<n>` | see below | Output size for an `+IMG` run. If only one is given, the other axis keeps the input size. |
| `+OUTDIR=<dir>` | `.` (`run.sh`: `<ip>/sim_out/`; `tools/run_sim.sh`: `ppm_out/<ip>/`) | Directory for the PPM files and, with `run.sh`, the VCD. The simulator cannot create directories, but the scripts do. |
| `+NO_PPM` | off | Do not write any PPM files. |
| `+QUICK` | off | Run a short representative suite instead of the full one: non-integer upscale, strong downscale and three back-to-back frames under back-pressure (filters: identity, maximum size, back-to-back). Used for slow runs such as gate-level simulation of large netlists. |
| `+TIMEOUT_MS=<n>` | 200 | Watchdog, in milliseconds of simulated time. Raise it for very large images. |
| `+QUICK` | off | Run a short representative suite instead of the full one: a non-integer upscale, a strong downscale and three back-to-back frames under back-pressure (filters: identity, maximum size, back-to-back). Used for gate-level simulation of large netlists. |
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

With the generated test suites, files are about 1–30 MB (the polyphase testbench is the largest). `+IMG` runs with large images produce correspondingly larger files; use `+NO_VCD` when you only need the images. View with any VCD viewer, e.g. Surfer or GTKWave (see below). Useful signals: `dut.m_axis_*` and `s_axis_*` for the streams, `dut.u_ctrl.state` for frame sequencing, and `dut.u_dda.o_x`/`o_y` for the source coordinates (in `scaler_bicubic`, `scaler_lanczos`, `scaler_trilinear` and `scaler_anisotropic` the core sits one level deeper, under `dut.u_core`; in `spatial_upscaler` the stages are `dut.u_scaler` and `dut.u_sharpen`, and the stream between them is `dut.mid_t*`).

### Opening waveforms in Surfer automatically

After a simulation that wrote a VCD, `<dir>/run.sh` and `tools/run_sim.sh` open it in [Surfer](https://surfer-project.org) when:

* Surfer is installed (`surfer` on `PATH`, or `SURFER=/path/to/surfer`), and
* a display is available (`DISPLAY` or `WAYLAND_DISPLAY` set, or macOS).

Surfer is started in the background, so the script still returns the test result as its exit status. It also opens after a failing run, which is usually when the waveform is most useful. The script prints the VCD path in every case.

| Control | Effect |
|---|---|
| (default) | open if Surfer and a display are available, otherwise do nothing |
| `-view` | always try; prints why if Surfer or a display is missing |
| `-noview` or `NO_VIEW=1` | never open |
| `+NO_VCD` | no VCD is written, so nothing is opened |

`tools/run_all.sh` sets `NO_VIEW=1`, so regressions never start a viewer, even with `VCD=1`. Surfer's log goes to `<dir>/sim_out/surfer.log` (or `build/<dir>/surfer.log` for Verilator). Example: `scaler_lanczos/run.sh -view +IMG=images/test_96x72.ppm`.

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
* **Buffering:** a `COVERAGE buffering` line reports the frame-store mode, the number of input beats accepted while an output frame was in progress, and the first-output latency in input rows. The testbench also enforces the mode's promise: no overlap and a latency of exactly one frame for a single frame buffer, overlap for ping-pong and line buffer in the back-to-back test, and output starting before half of a tall frame has arrived in line-buffer mode.
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
MODE=pingpong tools/run_all.sh                 # every IP built with PINGPONG=1
MODE=linebuf  tools/run_all.sh                 # every IP built with LINE_BUF=1
VCD=1 tools/run_all.sh                         # regression with waveform dumps
scaler_lanczos/run.sh -DTB_LINE_BUF=1          # one IP in one mode
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

Regression results. Every testbench passes on Icarus Verilog 12.0 in every frame-store mode it supports (35 runs), on the current RTL including the pipelined datapaths. On Verilator 5.020 all testbenches pass in frame mode on the current RTL; the Verilator ping-pong and line-buffer runs (all passing) were made before the datapaths were pipelined. Check counts are from Icarus; a few differ slightly between simulators because the random sequences differ.

| Testbench | frame | pingpong | linebuf | Checks (Icarus) |
|---|---|---|---|---|
| axi_checkers | PASS | | | legal traffic clean, every rule violation detected (procedural, plus SVA on Verilator) |
| axil_regbus | PASS | | | 2,067 (random AW/W order, stalled responses) |
| axil_split | PASS | | | 600 random accesses to two slaves, 305 checks |
| scaler_ctrl | PASS | PASS | (via IPs) | 6 capture scenarios, 963 checks; directed ping-pong test, 62 checks |
| banked_framebuf | PASS | | | TAPS 1–8 frame stores, 2 ping-pong and 2 ring instances, 497,352 tap checks |
| scaler_dda | PASS | | | 45,528 (random configurations, stalls and hold) |
| scaler_nearest | PASS | PASS | PASS | 10 tests, 6,462 checks |
| scaler_bilinear | PASS | PASS | PASS | 10 tests, 6,462 checks |
| scaler_edge_directed | PASS | PASS | PASS | 13 tests, 11,497 checks |
| scaler_polyphase (8 taps) | PASS | PASS | PASS | 12 tests, 7,267 checks |
| scaler_bicubic | PASS | PASS | PASS | 14 tests, 8,926 checks |
| scaler_lanczos | PASS | PASS | PASS | 12 tests, 7,916 checks |
| scaler_mip (3 levels, 4 probes) | PASS | PASS | n/a | 18 tests, 7,611 checks |
| scaler_trilinear | PASS | PASS | n/a | 14 tests, 6,884 checks |
| scaler_anisotropic | PASS | PASS | n/a | 18 tests, 7,629 checks |
| sharpen_cas | PASS | n/a | (always) | 16 tests, 7,800 checks |
| spatial_upscaler | PASS | PASS | PASS | 13 tests, 16,571 checks |

**Full-HD line-buffer run.** `scaler_lanczos` with `LINE_BUF=1` and `MAX_W=1920` was run on Verilator with a real 1920×1080 image scaled to 1280×720: all 921,600 output pixels matched the reference model bit-exactly, with zero protocol-assertion errors. The first output pixel appeared after 5 of the 1,080 input rows, and 2.07 million input beats were accepted while output was in progress. The whole run (build plus simulation) took about 3 minutes. To reproduce it with any 1080p image:

```bash
convert photo.jpg photo_1080p.ppm        # any 1920x1080 image, as binary PPM
tools/run_sim.sh scaler_lanczos -DTB_LINE_BUF=1 +IMG=photo_1080p.ppm +OUT_W=1280 +OUT_H=720 +NO_VCD +TIMEOUT_MS=100000
```

All runs finish with zero protocol-assertion errors (and zero SVA errors on Verilator).

The testbenches were also checked for sensitivity with deliberately injected RTL bugs: a rounding change, a mip averaging change, a CAS headroom change, a `sharpen_cas` line-buffer hazard (overwriting a line one row too early), and three buffering-mode bugs (the line buffer letting input overwrite a row one line early, the line buffer reading a row one line before it arrives, and ping-pong capturing into the buffer being output). All were caught, with hundreds to thousands of mismatches each.

## Scope notes and limitations

* **Temporal and AI upscalers** (TAAU, FSR 2/3, DLSS, XeSS) are not included. They need motion vectors, depth, frame history and, for AI upscalers, trained network weights supplied by a renderer, so they cannot be self-contained video scalers. `spatial_upscaler` provides the spatial FSR 1-style equivalent (Lanczos plus contrast-adaptive sharpening). It uses Lanczos-3 rather than FSR's edge-adaptive EASU kernel.
* **Classic pixel-art filters** (hqx, xBR) only work at fixed integer factors. `scaler_edge_directed` provides edge-aware interpolation at arbitrary factors instead.
* **Frame latency.** In the default mode a frame-buffer scaler adds one frame of latency and stalls its input while it outputs. Use `PINGPONG=1` to overlap capture and output, or `LINE_BUF=1` for a latency of a few lines. The mip-based IPs cannot use a line buffer, because the pyramid needs the whole frame; `sharpen_cas` is always line-buffered.
* **Line-buffer restrictions.** `STEP_Y` must be ≥ 0 (no vertical mirroring). A start-of-frame in the middle of a frame is flagged (`SOF_ERR`) but otherwise ignored, because the output side is already consuming the frame; the frame-buffer modes restart the capture instead.
* **Timing closure.** Kernel datapaths are written for clarity, with one combinational MAC tree per stage. For high clock rates, add pipeline registers inside the vertical and horizontal sums; the stall logic is unaffected.
* **Coefficient tables** have a bilinear default through `initial` blocks, which suits FPGA flows. ASIC flows must program the tables before enabling the IP.
* **CAS normalisation.** `sharpen_cas` replaces CAS's per-pixel divide with an equivalent-strength unsharp mask. It is exact at the minimum and maximum adaptive amount and monotonic in between (derivation §8).
* **Simulator notes.** The RTL has no `timescale` directive (only the checker files do); Verilator reports TIMESCALEMOD warnings, which are harmless. Icarus prints `sorry: constant selects in always_* processes`, an informational note about sensitivity lists that does not affect results.
