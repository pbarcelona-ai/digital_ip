# scaler_ctrl

**Type:** module

Common scaler control: register map 0x000–0x02F, forwarding of 0x040+ to the IP, AXI4-Stream frame capture with SOF/EOL error detection, and frame sequencing in three modes: single frame buffer (`NBUF=1`), ping-pong (`NBUF=2`: capture into one buffer while the generator reads the other), and line buffer (`LB_ROWS>0`: generation starts at SOF, with row-level flow control that holds the output scan until its source rows have arrived and holds the input until the oldest row still in use has been read).

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `tb/` — self-checking testbench `tb_scaler_ctrl.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

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
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |

### Waveforms

The last block of `tb/tb_scaler_ctrl.sv` calls `$dumpfile` / `$dumpvars(0, tb_scaler_ctrl)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_scaler_ctrl.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -I ../../scaler_tb_lib/src -s tb_scaler_ctrl -o sim.vvp -f build.f
vvp -n sim.vvp +VCD=tb_scaler_ctrl.vcd
```

With Verilator 5, use `tools/run_sim.sh scaler_ctrl [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

See the top-level `README.md` for the register map and `docs/coefficient_derivation.md` for programming values.
