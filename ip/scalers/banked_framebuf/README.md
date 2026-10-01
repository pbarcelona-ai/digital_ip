# banked_framebuf

**Type:** module

Frame store split over B×B RAM banks (B = next power of 2 ≥ TAPS) that returns any clamped TAPS×TAPS window every clock, with 2-cycle stall-able latency. `NBUF=2` holds two independent frames (`wr_buf`/`rd_buf`) for ping-pong operation. `RING>0` turns it into a line buffer of `RING` rows (row *y* in slot *y* mod `RING`; `RING` a power of two ≥ B, so a row's bank never changes); coordinates stay logical and are still clamped to the image.

The testbench checks TAPS = 1, 2, 3, 4, 6, 8 as frame stores, two ping-pong instances (random reads from either buffer), and two ring instances (rows written one at a time, with random windows read from the rows still held after each write).

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `synth.sh` — Yosys synthesis for Xilinx; `src/build.f` lists its sources (see below)
- `tb/` — self-checking testbench `banked_framebuf_tb.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** none

## Simulate

### run.sh (Icarus Verilog 12, no Python)

```bash
./run.sh                                        # full self-checking suite
./run.sh +NO_VCD                                # no waveform file
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_banked_framebuf.vcd`.

| Option | Effect |
|---|---|
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_banked_framebuf.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `-view` / `-noview` | Always / never open the VCD in [Surfer](https://surfer-project.org) after the run (default: open it if Surfer and a display are available; `NO_VIEW=1` also disables it) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |

### Waveforms

The last block of `tb/banked_framebuf_tb.sv` calls `$dumpfile` / `$dumpvars(0, tb_banked_framebuf)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_banked_framebuf.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -I ../../scaler_tb_lib/src -s tb_banked_framebuf -o sim.vvp -f build.f
vvp -n sim.vvp +VCD=tb_banked_framebuf.vcd
```

With Verilator 5, use `tools/run_sim.sh banked_framebuf [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

## Synthesize

```bash
./synth.sh                                      # Yosys, Xilinx 7-series, MAX_W=640 MAX_H=480
./synth.sh -p MAX_W=1920 -p MAX_H=1080        # other parameters
./synth.sh -family xcup                         # UltraScale+
./synth.sh --help
```

`synth.sh` converts the sources listed in `src/build.f` with sv2v, runs the shared Yosys script `tools/yosys/synth_xilinx.tcl` (compile, DSP48 packing, optimisation, memory to block RAM / LUT RAM, LUT/carry/FF mapping) and writes everything to `yosys/`. The hierarchical utilization table is in `yosys/utilization_hier.rpt`, the raw per-module statistics in `yosys/utilization.rpt`, the log in `yosys/synth.log`, and the mapped netlist in `yosys/banked_framebuf_netlist.v` / `.edf`. Requires Yosys ≥ 0.33 and sv2v; see *Synthesis* in the top-level README for results and details.

See the top-level `README.md` for the register map and `docs/coefficient_derivation.md` for programming values.

## Documentation

Full datasheet, parameters and port list: https://pbarcelona-ai.github.io/ip/banked-framebuf/
