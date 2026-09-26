# axi_checkers

**Type:** verification IP

Passive protocol checkers with functional coverage. `axis_checker` covers AXI4-Stream handshake rules (no valid retraction, stable payload under stall, no X) and video framing (tuser on the first beat, tlast at the end of each line, complete frames). `axil_checker` covers the AXI4-Lite master and slave rules on all five channels, response ordering and OKAY responses. Each rule is implemented twice: as procedural checks that run on every simulator including Icarus, and as SVA properties compiled with `+define+SVA_ON`. Coverage counters (orderings, stalls, stall-length buckets, back-to-back transfers, frames) are printed by `report()`. The testbench drives legal traffic (zero errors expected) and then violates every rule on purpose (each must be detected).

- `src/` — checker modules (simulation only; instantiate or bind next to an interface)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `tb/` — self-checking testbench `tb_axi_checkers.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** none

## Simulate

### run.sh (Icarus Verilog 12, no Python)

```bash
./run.sh                                        # full self-checking suite
./run.sh +NO_VCD                                # no waveform file
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_axi_checkers.vcd`.

| Option | Effect |
|---|---|
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_axi_checkers.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |

### Waveforms

The last block of `tb/tb_axi_checkers.sv` calls `$dumpfile` / `$dumpvars(0, tb_axi_checkers)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_axi_checkers.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -I ../../scaler_tb_lib/src -s tb_axi_checkers -o sim.vvp -f build.f
vvp -n sim.vvp +VCD=tb_axi_checkers.vcd
```

With Verilator 5, use `tools/run_sim.sh axi_checkers [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

See the top-level `README.md` for the register maps and protocol-checker details.
