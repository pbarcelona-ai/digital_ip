# scaler_lanczos

**Type:** IP

Lanczos-3 (6×6) scaler: scaler_polyphase with TAPS=6.

- `src/` — synthesizable RTL (the header comment of each file documents behaviour, arithmetic and registers)
- `run.sh` — one-command Icarus Verilog build and run (see below)
- `tb/` — self-checking testbench `tb_scaler_lanczos.sv` and `build.f`, the compile file list (every source needed, relative to `tb/`)

**Depends on:** `axil_regbus`, `scaler_ctrl`, `scaler_dda`, `banked_framebuf`, `scaler_polyphase`

## Buffering modes

Two compile-time parameters select how the IP stores the input (same registers, same output):

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
./run.sh +IMG=../images/test_96x72.ppm         # scale an image (3 default sizes)
./run.sh +IMG=photo.ppm +OUT_W=960 +OUT_H=720   # one chosen output size
./run.sh +NO_VCD +NO_PPM                        # fastest: no waveform, no images
./run.sh -DTB_PINGPONG=1                        # DUT built with PINGPONG=1
./run.sh -DTB_LINE_BUF=1                        # DUT built with LINE_BUF=1
./run.sh --help
```

`run.sh` can be called from any directory. It compiles `tb/build.f` with `iverilog -g2012`, runs `vvp`, and exits with 0 on `TB_RESULT: PASS` and 1 otherwise. It writes `sim_out/sim.log`, `sim_out/build.log`, the waveform `sim_out/tb_scaler_lanczos.vcd`, and PPM images `scaler_lanczos_tNN_in_WxH.ppm` (generated inputs) and `scaler_lanczos_tNN_out_WxH.ppm` (DUT output).

| Option | Effect |
|---|---|
| `+IMG=<file.ppm>` | Scale a binary PPM (P6) image instead of the generated patterns. `run.sh` sizes the build from the PPM header |
| `+OUT_W=<n> +OUT_H=<n>` | Output size for `+IMG` (default: 1.5× up, 0.4× down, ¼-height squeeze) |
| `+OUTDIR=<dir>` | Directory for PPM images and the VCD (`run.sh` default: `sim_out/`) |
| `+NO_PPM` | Do not write PPM images |
| `+VCD=<file>` | Waveform file name (default `<OUTDIR>/tb_scaler_lanczos.vcd`) |
| `+NO_VCD` | Do not dump waveforms (faster; VCDs are roughly 1–30 MB per run) |
| `+TIMEOUT_MS=<n>` | Watchdog in simulated ms (default 200) |
| `-DTB_PINGPONG=1` / `-DTB_LINE_BUF=1` | Compile-time: build the DUT in ping-pong / line-buffer mode |

### Waveforms

The last block of `tb/tb_scaler_lanczos.sv` calls `$dumpfile` / `$dumpvars(0, tb_scaler_lanczos)`, which dumps the whole testbench and DUT hierarchy. Open the result with a VCD viewer, for example `gtkwave sim_out/tb_scaler_lanczos.vcd`.

### Manual build

```bash
cd tb
iverilog -g2012 -DTB_MAX_W=640 -DTB_MAX_H=480 -I ../../scaler_tb_lib/src -s tb_scaler_lanczos -o sim.vvp -f build.f
vvp -n sim.vvp +IMG=photo.ppm +OUTDIR=. +VCD=tb_scaler_lanczos.vcd
```

The `TB_MAX_W`/`TB_MAX_H` defines (default 48 × 40) must be at least the `+IMG` size. `run.sh` sets them automatically.

With Verilator 5, use `tools/run_sim.sh scaler_lanczos [options]` from the repository root; it adds `--trace`, and `--assert +define+SVA_ON` so the SVA properties of the protocol checkers are active as well.

Icarus prints `sorry: constant selects in always_* processes ...` for some `always_comb` blocks. This is an informational note about sensitivity lists, not an error, and it does not affect results.

See the top-level `README.md` for the register map and `docs/coefficient_derivation.md` for programming values.
