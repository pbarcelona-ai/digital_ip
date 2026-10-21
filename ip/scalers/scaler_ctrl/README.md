# scaler_ctrl

Common control block for all scaler IPs. * AXI4-Lite slave (axil_regbus) implementing the common registers * forwards addresses >= 0x040 to the IP-specific ext_* bus * captures AXI4-Stream frames (tuser = SOF, tlast = EOL) into the frame store, dropping data before SOF and flagging errors * frame sequencing in one of three buffering modes: NBUF = 1, LB_ROWS = 0 frame buffer: capture a frame, then generate it; input is stalled while generating NBUF = 2, LB_ROWS = 0 double buffer (ping-pong): the next frame is captured into the other buffer while the current one is generated; input only stalls if both buffers are busy LB_ROWS > 0 line buffer: the frame store is a ring of LB_ROWS lines; generation starts at SOF and runs concurrently with capture, with row-level flow control in both directions (latency of a few lines). STEP_Y must be >= 0. Line-buffer flow control: the IP reports the source y coordinate of the next pixel its DDA will emit (lb_nxt_*) and of the pixels already emitted but whose rows are not yet read (lb_o_*, lb_a_*). From these the block derives need(y) = clamp(((y + LB_RND) >>> 16) - LB_CTR + LB_TAPS - 1, 0, H-1) top(y) = clamp(((y + LB_RND) >>> 16) - LB_CTR, 0, H-1) lb_hold = 1 while row need(next) has not been fully received, and input row r is accepted only while r < top(oldest in-flight pixel) + LB_ROWS. Common register map (byte offsets, 32-bit): 0x000 ID (RO) ASCII IP tag (IP_ID, first character in [31:24]) 0x004 VERSION (RO) ASCII "d.dd" (IP_VERSION of the scaler) 0x008 DATE (RO) BCD mm/dd/yyyy (IP_DATE of the scaler) 0x00C reserved (reads 0) 0x010 CTRL [0] ENABLE (RW) - run continuously while set 0x014 STATUS [0] BUSY [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR* [4] CAPTURING [5] GENERATING (* = write 1 clears) 0x018 IN_SIZE [15:0] width [31:16] height 0x01C OUT_SIZE [15:0] width [31:16] height 0x020 STEP_X unsigned 16.16 source pixels per output pixel 0x024 STEP_Y unsigned 16.16 0x028 OFFS_X signed 16.16 source position of output pixel 0; pixel- centre alignment as OpenCV cv::resize INTER_LINEAR is OFFS = STEP / 2 - 0.5, i.e. (STEP >> 1) - 0x8000 0x02C OFFS_Y signed 16.16 0x030 FRAME_CNT (RO) frames completed 0x034 IP_ID (RO) ASCII IP tag (same as ID) 0x038 CAPS (RO) IP capability word 0x03C MAX_SIZE (RO) [15:0] MAX_W [31:16] MAX_H 0x050-0x0FF forwarded to the IP (1-cycle read latency); the IP sees these addresses less 0x10 (0x040-0x0EF, the offsets its own decoder uses), so the ID block does not move its registers internally 0x100+ forwarded to the IP unchanged (coefficient tables) Responses: SLVERR for writes to the ID block (0x000-0x00F) and to the read-only words 0x030-0x03F, and for any access to the unmapped words 0x040-0x04F (0x00C reads 0, OKAY); the access has no effect. With EXT_WORDS >= 0 the IP has EXT_WORDS registers at 0x050 and up: accesses beyond them (0x050 + 4 * EXT_WORDS and up, including 0x100+) answer SLVERR and are not forwarded. EXT_WORDS = -1 (default) forwards the whole range and always answers OKAY there (the IP decodes it).

Common scaler control: register map 0x000–0x02F, forwarding of 0x040+ to the IP, AXI4-Stream frame capture with SOF/EOL error detection, and frame sequencing in three modes: single frame buffer (`NBUF=1`), ping-pong (`NBUF=2`: capture into one buffer while the generator reads the other), and line buffer (`LB_ROWS>0`: generation starts at SOF, with row-level flow control that holds the output scan until its source rows have arrived and holds the input until the oldest row still in use has been read).

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `synth.sh` — Yosys synthesis for Xilinx; `src/build.f` lists its sources (see below)
- `tb/` — self-checking testbench `scaler_ctrl_tb.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** `axil_regbus`

## Testbench

The default build runs six capture scenarios on a single-buffer DUT (tready low while generating, every pixel written once, SOF/EOL errors, re-sync). With `-DTB_NBUF=2` it runs a directed ping-pong test instead: frame A goes to buffer 0 and starts generation, frame B is captured into buffer 1 without a stall, frame C must stall until A's output finishes and then lands in buffer 0. It checks both buffers' contents, `gen_buf` for each generation and `FRAME_CNT`. The line-buffer mode is verified through the IP testbenches (`MODE=linebuf tools/run_all.sh`), where the output is checked against the reference model.

## Simulate

### run.sh (Icarus Verilog 12, no Python)

```bash
./run.sh                                        # full self-checking suite
./run.sh +NO_VCD                                # no waveform file
./run.sh -DTB_NBUF=2                            # ping-pong sequencing test
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_scaler_ctrl.vcd`.

| Option | Effect |
|---|---|
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_scaler_ctrl.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `-view` / `-noview` | Always / never open the VCD in [Surfer](https://surfer-project.org) after the run (default: open it if Surfer and a display are available; `NO_VIEW=1` also disables it) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |

### Waveforms

The last block of `tb/scaler_ctrl_tb.sv` calls `$dumpfile` / `$dumpvars(0, tb_scaler_ctrl)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_scaler_ctrl.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -I ../scaler_tb_lib/src -s tb_scaler_ctrl -o sim.vvp -f build.f
vvp -n sim.vvp +VCD=tb_scaler_ctrl.vcd
```

With Verilator 5, use `tools/run_sim.sh scaler_ctrl [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

## Synthesize

```bash
./synth.sh                                      # Yosys, Xilinx 7-series, the RTL defaults
./synth.sh -family xcup                         # UltraScale+
./synth.sh --help
```

`synth.sh` converts the sources listed in `src/build.f` with sv2v, runs the shared Yosys script `tools/yosys/synth_xilinx.tcl` (compile, DSP48 packing, optimisation, memory to block RAM / LUT RAM, LUT/carry/FF mapping) and writes everything to `yosys/`. The hierarchical utilization table is in `yosys/utilization_hier.rpt`, the raw per-module statistics in `yosys/utilization.rpt`, the log in `yosys/synth.log`, and the mapped netlist in `yosys/scaler_ctrl_netlist.v` / `.edf`. Requires Yosys ≥ 0.33 and sv2v; see *Synthesis* in the top-level README for results and details.

See the top-level `README.md` for the register map and `docs/coefficient_derivation.md` for programming values.

<!-- readme:begin (generated by ip/scripts/gen_readmes.py; edits here are overwritten) -->
## Make targets

```
Targets: test, sim, synth, synplify, gatesim, docs, diagrams, diagram-check, clean, list
Per-IP: make -C scalers/scaler_bicubic test|sim|synth|gatesim|clean
Common:  make test [IP=scaler_bicubic] [MODE=frame|pingpong|linebuf] [VCD=1]
         make cov [IP=scaler_bicubic] [MODE=...]  (Verilator code coverage -> build/coverage/<IP or scalers>)
         make wave IP=scaler_bicubic [RUN_ARGS="+IMG=photo.ppm"]  (VCD, opened in Surfer)
         make sim [IP=scaler_bicubic] [RUN_ARGS="+IMG=photo.ppm"]
         make synth [IP=scaler_bicubic] [SYNTH_ARGS="-p MAX_W=1920"]
         make gatesim IP=scaler_bicubic [GATESIM_ARGS="+QUICK"]
         make diagrams [DIAGRAM_IPS="scaler_bilinear scaler_lanczos"] [DIAGRAM_ARGS="--dot-only"]
```

## Tests

| Testbench | Test | Description |
|-----------|------|-------------|
| `scaler_ctrl_tb` | `scaler_ctrl_tb` | one test: Self-checking testbench for scaler_ctrl. |

## Registers

- AXI4-Lite register map: described in the header of [`scaler_ctrl.sv`](src/scaler_ctrl.sv) (to move to src/include/ as a generated map, see [REGMAP_MIGRATION.md](../../docs/REGMAP_MIGRATION.md))

## Prompt

- [scaler_ctrl_prompt.md](docs/scaler_ctrl_prompt.md): the prompt that regenerates this block, reverse-engineered from its sources (`python3 ../../scripts/make_ip_prompts.py --only scaler_ctrl`)
<!-- readme:end -->

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG.

### Data flow

[![Data flow of `scaler_ctrl`](docs/scaler_ctrl_dataflow.svg)](docs/scaler_ctrl_dataflow.svg)
<!-- diagrams:end -->

## Documentation

Full datasheet, parameters and port list: https://pbarcelona-ai.github.io/ip/scaler-ctrl/
