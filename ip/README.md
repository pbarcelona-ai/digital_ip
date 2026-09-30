# SystemVerilog IP library

Reusable, parameterized SystemVerilog IP by Paul Barcelona. Developed for a 100 MHz clock but written to run at any clock (each IP documents its own limits). Registers use AXI4-Lite, data uses AXI4-Stream, every IP has a self-checking testbench, and every IP goes through the same Yosys Xilinx (7 series) synthesis flow with reports.

## Layout

```
<category>/<ip>/{src,tb,scripts,docs}/  Independent RTL, tests, manifests, and docs
<category>/<ip>/Makefile                Local test, synthesis, docs, and diagram targets
shared/{src,tb}/                        Shared RTL helpers and verification models
scalers/scaler_tb_lib/                  Shared scaler-only testbench utilities
include/                                ip_version_pkg.sv
assertions/                             Concurrent SVA protocol checkers
scripts/                                Root runners and generators
tools/                                  Shared scaler regression and documentation tools
docs/                                   Generated catalog and scaler reference material
images/                                 Scaler sample input
examples/regmap/                        Register-map generator example
```

Categories: `common` (small blocks and DSP), `cdc`, `fifo`, `math`, `memory`, `timing`, `bus`, `integrity`, `peripherals`, `scalers`.

## Use

```
make -C <category>/<ip> test                     # local simulation via .tools
make -C <category>/<ip> yosys                    # local Yosys Xilinx flow
make -C <category>/<ip> docs                     # generate HTML and Markdown catalog
make -C <category>/<ip> diagrams                 # generate module hierarchy DOT/SVG
make test IP=<ip>                                # same IP through root orchestration
make test                                        # all root and scaler simulations
make test IP=scaler_nearest                      # one flattened scaler module
make scaler-test                                 # scaler-only regression
scripts/run_sim.sh <ip> [--vcd|--wave|--lint]    # outputs under build/sim/<ip>/
scripts/run_yosys.sh <ip>                        # outputs under build/yosys/<ip>/
scripts/run_sva.sh                               # concurrent assertions under Verilator
python3 scripts/regmap_gen.py map.json outdir   # register block + C header + Markdown
python3 scripts/gen_docs.py                      # regenerate per-IP HTML and catalog
python3 scripts/make_block_diagrams.py --dot-only # generate DOT without Graphviz
```

`scripts/ips.csv` lists 75 general-purpose modules plus 17 scaler modules as `name,category,top_module`; each module lives at `<category>/<name>`. RTL and testbench manifest paths are relative to that IP's root. Shared implementation and BFM dependencies are explicit under `shared/`. Scaler modules use the dedicated runners in `tools/` and are grouped under `scalers/`. `--vcd` writes a VCD; `--wave` opens it in Surfer if installed.

## What every IP provides

Synchronous reset, documented clock-domain assumptions, elaboration-time parameter validation (`$error`), synthesizable RTL with no vendor primitives, immediate assertions inside `ifndef SYNTHESIS`, a self-checking testbench, deterministic reset state, an `IP_VERSION` localparam (1.0.0) and a header stating latency, timing assumptions and error behavior. The header text of each top module is collected in `docs/IP_CATALOG.md`.

## Name mapping and renames

- `watchdog_timer` is the `watchdog` IP; `uart_core` is `uart` (top `uart_top`, built from `uart_tx`, `uart_rx`, `uart_baud`); `uart_tx` and `uart_rx` also have standalone testbenches.
- Renamed to avoid clashes: the multichannel edge capture peripheral is `edge_event_capture`; the reset controller is `reset_ctrl` (top `ip_reset_sync_top`); the AXI-Lite clock crossing is `axi4_lite_cdc`, while `clock_domain_bridge` is the generic multi-bit handshake crossing.
- `cordic`, `dds`, `fir`, and `cic` are independent modules; category names remain catalog metadata.

The scaler modules live under [scalers](scalers/). Their overview is [SCALER_README.md](SCALER_README.md), reference documentation is in [docs/scaler](docs/scaler), and shared tooling is in [tools](tools). The default `make test` runs both the general IP and scaler regressions.

## Tool selection

Edit `.tools` to select the active `SIMULATOR`, `PYTHON_SIMULATOR`, `SYNTHESIS`, and `PLACE_ROUTE` backends; the root and per-IP Makefiles and runners read this file. Simulation options are `iverilog`, `vcs`, `modelsim`, `questa`, and `questasim`; synthesis options are `yosys` and `synplify`; place and route supports `vivado`. Command-line overrides are available, for example `make test SIM=questa`, `make synth SYNTH_TOOL=synplify`, and `make pnr IP=<ip> PNR_TOOL=vivado`.

Synplify and Vivado are client-specific hooks, not bundled project flows. Configure `SYNPLIFY_RUNNER` with a wrapper executable and `PLACE_ROUTE=vivado` plus `VIVADO_TCL` with a project Tcl script. The scripts pass each IP's directory, top module, source manifest, and output directory to those hooks. VCS, ModelSim, Questa, Synplify, and Vivado are not validated in this environment.

## Register-map generator

`scripts/regmap_gen.py` turns a JSON description (RW, RO, W1C, W1S registers with fields) into an AXI4-Lite register block built on `axi4_lite_regs`, a C header and a Markdown table. `examples/regmap/demo_regs.json` is the example; its generated output is the `demo_regs` IP, which has its own testbench, so the generator output is verified.

## Limits and honest notes

- Yosys 0.33 has no static timing analysis. The "logic depth" in the reports counts coarse cells and is a rough indicator only; real timing needs Vivado/place-and-route.
- A dual-clock true dual-port RAM cannot be mapped to block RAM by Yosys 0.33. `true_dual_port_ram` defaults to `DUAL_CLOCK=0` (maps); `DUAL_CLOCK=1` is simulation-verified only.
- Concurrent SVA (assertions/) runs only under Verilator 5 (`run_sva.sh`); iverilog 12 and Yosys skip it. The RTL uses immediate assertions, which iverilog does run.
- `pcie_tl_ep` is transaction layer only (no PHY, data link layer or LTSSM). `usb_fs_sie` is the serial interface engine only (no enumeration or protocol stack) and is simulation-verified at 48, 60 and 100 MHz clocks only.
- `sdio_host` supports single-block transfers in SD mode (1-bit and 4-bit); no multi-block, SPI mode, UHS or DMA. `spi_flash_ctrl` uses 3-byte addressing and single-bit SPI mode 0. `eth_mac_if` is GMII single clock with no MDIO or flow control. Models of cards and flash in the testbenches are behavioral and were written by the same author as the RTL, so they share assumptions; test against real devices or independent models before relying on them.
- Testbench coverage is directed plus randomized checking, not formal proof and not a coverage-driven regression. Everything was verified in simulation and synthesized with Yosys, none of it on hardware.
- `ecc_memory_ctrl` shows a long combinational path in Yosys (scrub decode plus re-encode); add a pipeline stage if it does not meet 100 MHz in Vivado. Timing of every IP is unverified beyond the rough depth numbers.
- Bug found by the SVA checker late in the work: `axi4_lite_slave` accepted a new write while the previous response was pending (fixed; the slave now allows one outstanding write).

## Toolchain notes

Yosys 0.33 (apt), Icarus Verilog 12, Verilator 5.020. Constructs avoided because of tool limits: `return` in functions, `parameter string`, `int'()` casts, unpacked-array ports, generate-level `$error` outside an `if`. See `docs/IP_CATALOG.md` for per-IP details and `docs/STATUS.md` for the last verification results.
