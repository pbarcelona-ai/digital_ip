# spatial_upscaler

**Type:** IP (composite)

FSR 1-style spatial upscaler: `scaler_lanczos` resampling followed by `sharpen_cas`, behind a single AXI4-Lite port (`axil_split`). Scaler registers are at 0x0000–0x3FFF, sharpener registers at 0x4000–0x40FF. The sharpener SIZE must be programmed to the scaler OUT_SIZE. The testbench models both stages exactly: the Lanczos output image first, then CAS applied to it.

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `synth.sh` — Yosys synthesis for Xilinx; `src/build.f` lists its sources (see below)
- `tb/` — self-checking testbench `spatial_upscaler_tb.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** `axil_split`, `axil_regbus`, `scaler_lanczos`, `scaler_polyphase`, `scaler_ctrl`, `scaler_dda`, `banked_framebuf`, `sharpen_cas`

## Buffering modes

Two compile-time parameters select how the scaler stage stores the input (same registers, same output):

| Parameters | Frame store | Behaviour |
|---|---|---|
| `PINGPONG=0, LINE_BUF=0` (default) | one frame | capture a frame, then output it; input stalls during output |
| `PINGPONG=1` | two frames | the next frame is captured while the current one is output |
| `LINE_BUF=1` | ring of 4–16 lines | output starts after a few input lines; about `8 × MAX_W` pixels for 1080p-class widths |

In line-buffer mode `STEP_Y` must be ≥ 0. See *Buffering modes* in the top-level README.

## Simulate

### run.sh (Icarus Verilog 12, no Python)

```bash
./run.sh                                        # full self-checking suite
./run.sh +IMG=../images/test_96x72.ppm         # process an image
./run.sh +IMG=photo.ppm +OUT_W=1920 +OUT_H=1080 +SHARP=200
./run.sh +NO_VCD +NO_PPM                        # fastest: no waveform, no images
./run.sh -DTB_PINGPONG=1                        # DUT built with PINGPONG=1
./run.sh -DTB_LINE_BUF=1                        # DUT built with LINE_BUF=1
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_spatial_upscaler.vcd`, and PPM images `spatial_upscaler_tNN_in_WxH.ppm` (generated inputs) and `spatial_upscaler_tNN_out_WxH.ppm` (DUT output).

| Option | Effect |
|---|---|
| `+IMG=<file.ppm>` | Process a binary PPM (P6) image instead of the generated patterns. `run.sh` sizes the build from the PPM header |
| `+OUT_W=<n> +OUT_H=<n>` | Output size for `+IMG` (default: 1.5× up, 0.4× down, ¼-height squeeze; at most 2× the input per axis) |
| `+OUTDIR=<dir>` | Directory for PPM images and the VCD (`run.sh` default: `sim_out/`) |
| `+NO_PPM` | Do not write PPM images |
| `+QUICK` | Short representative suite (3 tests) instead of the full suite, e.g. for gate-level runs |
| `+SHARP=<0..256>` | SHARPNESS for `+IMG` runs (default 128) |
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_spatial_upscaler.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `-view` / `-noview` | Always / never open the VCD in [Surfer](https://surfer-project.org) after the run (default: open it if Surfer and a display are available; `NO_VIEW=1` also disables it) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |
| `-DTB_PINGPONG=1` / `-DTB_LINE_BUF=1` | Compile-time: build the DUT in ping-pong / line-buffer mode |

### Waveforms

The last block of `tb/spatial_upscaler_tb.sv` calls `$dumpfile` / `$dumpvars(0, tb_spatial_upscaler)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_spatial_upscaler.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -DTB_MAX_W=640 -DTB_MAX_H=480 -I ../scaler_tb_lib/src -s tb_spatial_upscaler -o sim.vvp -f build.f
vvp -n sim.vvp +IMG=photo.ppm +OUTDIR=. +VCD=tb_spatial_upscaler.vcd
```

The `TB_MAX_W`/`TB_MAX_H` defines (default 48 × 40) must be at least the `+IMG` size. `run.sh` sets them automatically.

With Verilator 5, use `tools/run_sim.sh spatial_upscaler [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

## Synthesize

```bash
./synth.sh                                      # Yosys, Xilinx 7-series, MAX_W=640 MAX_H=480
./synth.sh -p MAX_W=1920 -p MAX_H=1080        # other parameters
./synth.sh -p LINE_BUF=1 -p MAX_W=1920         # 1080p line-buffer build
./synth.sh -family xcup                         # UltraScale+
./synth.sh --help
```

`synth.sh` converts the sources listed in `src/build.f` with sv2v, runs the shared Yosys script `tools/yosys/synth_xilinx.tcl` (compile, DSP48 packing, optimisation, memory to block RAM / LUT RAM, LUT/carry/FF mapping) and writes everything to `yosys/`. The hierarchical utilization table is in `yosys/utilization_hier.rpt`, the raw per-module statistics in `yosys/utilization.rpt`, the log in `yosys/synth.log`, and the mapped netlist in `yosys/spatial_upscaler_netlist.v` / `.edf`. Requires Yosys ≥ 0.33 and sv2v; see *Synthesis* in the top-level README for results and details.

**Gate-level check.** `tools/gatesim.sh spatial_upscaler` (from the repository root) synthesizes this IP at the testbench size with the same flow and runs the unchanged self-checking testbench on the mapped Xilinx netlist, including its block RAMs and DSP48s (using Xilinx's functional UNISIM models, downloaded on first use). Add `-p NAME=VALUE` / `-D<define>` for other builds, e.g. `-p LINE_BUF=1 -DTB_LINE_BUF=1`; `-vcd` dumps a gate-level VCD and opens it in Surfer.

See the top-level `README.md` for the register maps and protocol-checker details.

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG.

### RTL hierarchy

[![RTL hierarchy of `spatial_upscaler`](docs/block_diagram.svg)](docs/block_diagram.svg)

### Data flow

[![Data flow of `spatial_upscaler`](docs/spatial_upscaler_dataflow.svg)](docs/spatial_upscaler_dataflow.svg)
<!-- diagrams:end -->

## Documentation

Full datasheet, parameters and port list: https://pbarcelona-ai.github.io/ip/spatial-upscaler/
