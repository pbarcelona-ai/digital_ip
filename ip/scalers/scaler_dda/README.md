# scaler_dda

**Type:** module

Raster scan of the output image producing 16.16 source coordinates `OFFS + o·STEP` by exact accumulation, with SOF/EOL/EOF flags and pipeline stall.

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `synth.sh` — Yosys synthesis for Xilinx; `src/build.f` lists its sources (see below)
- `tb/` — self-checking testbench `scaler_dda_tb.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** none

A `hold` input inserts bubbles without advancing the scan, and `nxt_y` exposes the source y of the next pixel. Line-buffer mode uses both to wait for source rows.

## Simulate

### run.sh (Icarus Verilog 12, no Python)

```bash
./run.sh                                        # full self-checking suite
./run.sh +NO_VCD                                # no waveform file
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_scaler_dda.vcd`.

| Option | Effect |
|---|---|
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_scaler_dda.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `-view` / `-noview` | Always / never open the VCD in [Surfer](https://surfer-project.org) after the run (default: open it if Surfer and a display are available; `NO_VIEW=1` also disables it) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |

### Waveforms

The last block of `tb/scaler_dda_tb.sv` calls `$dumpfile` / `$dumpvars(0, tb_scaler_dda)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_scaler_dda.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -I ../scaler_tb_lib/src -s tb_scaler_dda -o sim.vvp -f build.f
vvp -n sim.vvp +VCD=tb_scaler_dda.vcd
```

With Verilator 5, use `tools/run_sim.sh scaler_dda [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

## Synthesize

```bash
./synth.sh                                      # Yosys, Xilinx 7-series, the RTL defaults
./synth.sh -family xcup                         # UltraScale+
./synth.sh --help
```

`synth.sh` converts the sources listed in `src/build.f` with sv2v, runs the shared Yosys script `tools/yosys/synth_xilinx.tcl` (compile, DSP48 packing, optimisation, memory to block RAM / LUT RAM, LUT/carry/FF mapping) and writes everything to `yosys/`. The hierarchical utilization table is in `yosys/utilization_hier.rpt`, the raw per-module statistics in `yosys/utilization.rpt`, the log in `yosys/synth.log`, and the mapped netlist in `yosys/scaler_dda_netlist.v` / `.edf`. Requires Yosys ≥ 0.33 and sv2v; see *Synthesis* in the top-level README for results and details.

See the top-level `README.md` for the register map and `docs/coefficient_derivation.md` for programming values.
