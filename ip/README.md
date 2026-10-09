# SystemVerilog IP library

Reusable, parameterized SystemVerilog IP by FPGA Cores 4 U. Browse the documented catalog at https://pbarcelona-ai.github.io/ip/. MIT licensed (see [LICENSE](../LICENSE)). Developed for a 100 MHz clock but written to run at any clock (each IP documents its own limits). Registers use AXI4-Lite, data uses AXI4-Stream, every IP has a self-checking testbench, and every IP goes through the same Yosys Xilinx (7 series) synthesis flow with reports.

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
make cov IP=<ip>                                 # code coverage -> build/coverage/<ip>/summary.txt
make cov                                         # whole regression -> build/coverage/all/summary.txt
scripts/run_yosys.sh <ip>                        # outputs under build/yosys/<ip>/
scripts/run_sva.sh                               # concurrent assertions under Verilator
python3 scripts/regmap_gen.py map.json outdir   # register block + C header + Markdown
python3 scripts/gen_docs.py                      # regenerate per-IP HTML and catalog
python3 scripts/make_block_diagrams.py --dot-only # generate DOT without Graphviz
```

`scripts/ips.csv` lists 75 general-purpose modules plus 17 scaler modules as `name,category,top_module`; each module lives at `<category>/<name>`. RTL and testbench manifest paths are relative to that IP's root. Shared implementation and BFM dependencies are explicit under `shared/`. Scaler modules use the dedicated runners in `tools/` and are grouped under `scalers/`. `--vcd` writes a VCD; `--wave` opens it in Surfer if installed.

## Testbench bus functional models

Protocol partners of the DUTs live in [shared/tb/lib](shared/tb/lib), one `<protocol>_bfm.sv` each, and are used by the IP testbenches and by the system testbenches (`py_soc`, `video_pipeline`, `image_processing/video_processor`) to drive and check the DUT pins:

| BFM | Role | Used by |
|-----|------|---------|
| `axil_bfm` | AXI4-Lite manager (optional BREADY / RREADY back pressure) | every register-mapped IP |
| `uart_bfm` | UART device: transmitter with error injection, receiver with parity / stop checks and text lines | uart, uart_tx, uart_rx, video_processor (firmware report) |
| `i2c_bfm` | I2C target with a 256-byte memory, clock stretching | i2c_master, py_soc, video_processor (camera CCI, EEPROM) |
| `spi_bfm` / `spi_master_bfm` | SPI target / SPI controller, all modes | spi_master / spi_slave |
| `spi_flash_bfm` | SPI NOR flash | spi_flash_ctrl, py_soc, video_processor (boot flash) |
| `i2s_bfm` | I2S codec (decodes the DUT output, sends its own samples) | i2s |
| `eth_bfm` | GMII PHY: transmit monitor, loopback with bit-flip injection, frame injection with rx_er | eth_mac_if |
| `sdio_bfm` | SD card and the pulled-up CMD / DAT bus | sdio_host |
| `usb_bfm` | USB full-speed host: NRZI / stuffing transmitter, independent decoder | usb_fs_sie |
| `pcie_bfm` | PCIe root complex at the TLP layer | pcie_tl_ep |
| `quad_bfm` | incremental encoder (A / B / Z) | quadrature_decoder |
| `csi2_bfm` | MIPI CSI-2 camera (D-PHY lane driver) | csi2_rx, video_pipeline, video_processor |
| `dsi_bfm` | MIPI DSI receiver | dsi_tx, video_pipeline |
| `tmds_bfm` + `hdmi_bfm` | TMDS deserialiser + HDMI / DVI decoder | tmds_serializer, hdmi_tx, video_pipeline, video_processor |
| `lvds_bfm` | LVDS 7:1 deserialiser + VESA 24 bpp decoder | lvds_serializer, video_processor |

## Code coverage

`make cov` (root, per-IP directory, or `scalers` via `tools/common.mk`) runs the normal testbenches with code coverage. `scripts/run_cov.sh <out_dir> <command...>` wraps any simulation command: the `iverilog` and `vvp` shims in `tools/cov` are put first on `PATH`, so the command's Icarus build is rebuilt with `verilator --binary --timing --coverage` (line, branch, expression, and toggle coverage) without changing any run script. The same mechanism covers `py_soc`, the scaler `run.sh` flows, and the `image_processing` systems (`make cov` there). Verilator cocotb testbenches (`tb/python/run_python.py`) add `--coverage` when `COV_DIR` is set; cocotb under Icarus is not covered.

`tools/cov/cov_report.py` merges every run, combines instances of the same module, leaves testbench files out, and writes `summary.txt`/`summary.csv` (per RTL file), `merged.dat`, `coverage.info` (LCOV: `genhtml coverage.info -o html`), and `annotated/` sources (`%000000` marks lines never hit). With `SIM=vcs` or `SIM=questa`, the vendor runners collect native coverage instead (`COV=1`) and the databases are merged with `urg` / `vcover`; those vendor paths are not validated in this environment.

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

<!-- diagrams:begin (generated by ip/scripts/update_readme_diagrams.py; edits here are overwritten) -->
## Diagrams

Data-flow diagrams are generated from the RTL by `ip/scripts/make_dataflow_diagrams.py`: inputs on the left, outputs on the right, registers as double-bordered boxes grouped by the `always` block that drives them, combinational signals as ellipses, sub-modules in yellow, AXI4-Stream / AXI4 / AXI4-Lite buses as one teal line. Click a diagram for the full-size SVG. Every IP's `docs/` folder holds its diagrams; regenerate them with `python3 scripts/make_dataflow_diagrams.py` (data flow) and `make -C <category>/<ip> diagrams` (hierarchy).

### Bus

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`axi4_lite_decoder`](bus/axi4_lite_decoder) | - | - | [data flow](bus/axi4_lite_decoder/docs/axi4_lite_decoder_dataflow.svg) |
| [`axi4_lite_mux`](bus/axi4_lite_mux) | - | [hierarchy](bus/axi4_lite_mux/docs/block_diagram.svg) | [data flow](bus/axi4_lite_mux/docs/axi4_lite_mux_dataflow.svg) |
| [`axi4_lite_regs`](bus/axi4_lite_regs) | - | [hierarchy](bus/axi4_lite_regs/docs/block_diagram.svg) | [data flow](bus/axi4_lite_regs/docs/axi4_lite_regs_dataflow.svg) |
| [`axi4_lite_slave`](bus/axi4_lite_slave) | - | - | [data flow](bus/axi4_lite_slave/docs/axi4_lite_slave_dataflow.svg) |
| [`axi_stream_arbiter`](bus/axi_stream_arbiter) | - | - | [data flow](bus/axi_stream_arbiter/docs/axi_stream_arbiter_dataflow.svg) |
| [`axi_stream_fifo`](bus/axi_stream_fifo) | - | [hierarchy](bus/axi_stream_fifo/docs/block_diagram.svg) | [data flow](bus/axi_stream_fifo/docs/axi_stream_fifo_dataflow.svg) |
| [`axi_stream_width_converter`](bus/axi_stream_width_converter) | - | - | [data flow](bus/axi_stream_width_converter/docs/axi_stream_width_converter_dataflow.svg) |
| [`axis_dma`](bus/axis_dma) | - | [hierarchy](bus/axis_dma/docs/block_diagram.svg) | [data flow](bus/axis_dma/docs/axis_dma_dataflow.svg) |
| [`demo_regs`](bus/demo_regs) | - | [hierarchy](bus/demo_regs/docs/block_diagram.svg) | [data flow](bus/demo_regs/docs/demo_regs_dataflow.svg) |
| [`dma_engine`](bus/dma_engine) | - | [hierarchy](bus/dma_engine/docs/block_diagram.svg) | [data flow](bus/dma_engine/docs/dma_engine_dataflow.svg) |
| [`packet_formatter`](bus/packet_formatter) | - | - | [data flow](bus/packet_formatter/docs/packet_formatter_dataflow.svg) |
| [`packet_parser`](bus/packet_parser) | - | - | [data flow](bus/packet_parser/docs/packet_parser_dataflow.svg) |

### CDC

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`axi4_lite_cdc`](cdc/axi4_lite_cdc) | - | [hierarchy](cdc/axi4_lite_cdc/docs/block_diagram.svg) | [data flow](cdc/axi4_lite_cdc/docs/axi4_lite_cdc_dataflow.svg) |
| [`axis_async_bridge`](cdc/axis_async_bridge) | - | [hierarchy](cdc/axis_async_bridge/docs/block_diagram.svg) | [data flow](cdc/axis_async_bridge/docs/axis_async_bridge_dataflow.svg) |
| [`bit_sync`](cdc/bit_sync) | - | - | [data flow](cdc/bit_sync/docs/bit_sync_dataflow.svg) |
| [`clock_domain_bridge`](cdc/clock_domain_bridge) | - | [hierarchy](cdc/clock_domain_bridge/docs/block_diagram.svg) | [data flow](cdc/clock_domain_bridge/docs/clock_domain_bridge_dataflow.svg) |
| [`pulse_sync`](cdc/pulse_sync) | - | [hierarchy](cdc/pulse_sync/docs/block_diagram.svg) | [data flow](cdc/pulse_sync/docs/pulse_sync_dataflow.svg) |
| [`reset_ctrl`](cdc/reset_ctrl) | - | [hierarchy](cdc/reset_ctrl/docs/block_diagram.svg) | [data flow](cdc/reset_ctrl/docs/reset_ctrl_dataflow.svg) |
| [`reset_sync`](cdc/reset_sync) | - | - | [data flow](cdc/reset_sync/docs/reset_sync_dataflow.svg) |
| [`toggle_sync`](cdc/toggle_sync) | - | [hierarchy](cdc/toggle_sync/docs/block_diagram.svg) | [data flow](cdc/toggle_sync/docs/toggle_sync_dataflow.svg) |

### Common

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`cic`](common/cic) | - | - | [data flow](common/cic/docs/cic_dataflow.svg) |
| [`cordic`](common/cordic) | - | - | [data flow](common/cordic/docs/cordic_dataflow.svg) |
| [`dds`](common/dds) | - | [hierarchy](common/dds/docs/block_diagram.svg) | [data flow](common/dds/docs/dds_dataflow.svg) |
| [`edge_detect`](common/edge_detect) | - | - | [data flow](common/edge_detect/docs/edge_detect_dataflow.svg) |
| [`fir`](common/fir) | - | - | [data flow](common/fir/docs/fir_dataflow.svg) |
| [`onehot_decoder`](common/onehot_decoder) | - | - | [data flow](common/onehot_decoder/docs/onehot_decoder_dataflow.svg) |
| [`priority_encoder`](common/priority_encoder) | - | - | [data flow](common/priority_encoder/docs/priority_encoder_dataflow.svg) |

### CPU

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`py_core`](cpu/py_core) | [block](cpu/py_core/docs/py_core_block_diagram.svg), [state machine](cpu/py_core/docs/py_core_fsm.svg) | - | [data flow](cpu/py_core/docs/py_core_dataflow.svg) |
| [`py_soc`](cpu/py_soc) | [block](cpu/py_soc/docs/py_soc_block_diagram.svg) | [hierarchy](cpu/py_soc/docs/block_diagram.svg) | [data flow](cpu/py_soc/docs/py_soc_dataflow.svg) |

### FIFO

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`async_fifo`](fifo/async_fifo) | - | - | [data flow](fifo/async_fifo/docs/async_fifo_dataflow.svg) |
| [`fallthrough_fifo`](fifo/fallthrough_fifo) | - | - | [data flow](fifo/fallthrough_fifo/docs/fallthrough_fifo_dataflow.svg) |
| [`packet_fifo`](fifo/packet_fifo) | - | - | [data flow](fifo/packet_fifo/docs/packet_fifo_dataflow.svg) |
| [`sync_fifo`](fifo/sync_fifo) | - | - | [data flow](fifo/sync_fifo/docs/sync_fifo_dataflow.svg) |

### Integrity

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`checksum`](integrity/checksum) | - | - | [data flow](integrity/checksum/docs/checksum_dataflow.svg) |
| [`crc16`](integrity/crc16) | - | [hierarchy](integrity/crc16/docs/block_diagram.svg) | [data flow](integrity/crc16/docs/crc16_dataflow.svg) |
| [`crc32`](integrity/crc32) | - | [hierarchy](integrity/crc32/docs/block_diagram.svg) | [data flow](integrity/crc32/docs/crc32_dataflow.svg) |
| [`crc8`](integrity/crc8) | - | [hierarchy](integrity/crc8/docs/block_diagram.svg) | [data flow](integrity/crc8/docs/crc8_dataflow.svg) |
| [`ecc_memory_ctrl`](integrity/ecc_memory_ctrl) | - | [hierarchy](integrity/ecc_memory_ctrl/docs/block_diagram.svg) | [data flow](integrity/ecc_memory_ctrl/docs/ecc_memory_ctrl_dataflow.svg) |
| [`error_status`](integrity/error_status) | - | - | [data flow](integrity/error_status/docs/error_status_dataflow.svg) |
| [`lfsr`](integrity/lfsr) | - | - | [data flow](integrity/lfsr/docs/lfsr_dataflow.svg) |
| [`parity_check`](integrity/parity_check) | - | - | [data flow](integrity/parity_check/docs/parity_check_dataflow.svg) |
| [`parity_gen`](integrity/parity_gen) | - | - | [data flow](integrity/parity_gen/docs/parity_gen_dataflow.svg) |

### Math

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`mac`](math/mac) | - | - | [data flow](math/mac/docs/mac_dataflow.svg) |

### Memory

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`memory_arbiter`](memory/memory_arbiter) | - | - | [data flow](memory/memory_arbiter/docs/memory_arbiter_dataflow.svg) |
| [`register_file`](memory/register_file) | - | - | [data flow](memory/register_file/docs/register_file_dataflow.svg) |
| [`rom`](memory/rom) | - | - | [data flow](memory/rom/docs/rom_dataflow.svg) |
| [`simple_dual_port_ram`](memory/simple_dual_port_ram) | - | - | [data flow](memory/simple_dual_port_ram/docs/simple_dual_port_ram_dataflow.svg) |
| [`single_port_ram`](memory/single_port_ram) | - | - | [data flow](memory/single_port_ram/docs/single_port_ram_dataflow.svg) |
| [`true_dual_port_ram`](memory/true_dual_port_ram) | - | - | [data flow](memory/true_dual_port_ram/docs/true_dual_port_ram_dataflow.svg) |

### Peripherals

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`edge_event_capture`](peripherals/edge_event_capture) | - | [hierarchy](peripherals/edge_event_capture/docs/block_diagram.svg) | [data flow](peripherals/edge_event_capture/docs/edge_event_capture_dataflow.svg) |
| [`eth_mac_if`](peripherals/eth_mac_if) | - | [hierarchy](peripherals/eth_mac_if/docs/block_diagram.svg) | [data flow](peripherals/eth_mac_if/docs/eth_mac_if_dataflow.svg) |
| [`gpio`](peripherals/gpio) | - | [hierarchy](peripherals/gpio/docs/block_diagram.svg) | [data flow](peripherals/gpio/docs/gpio_dataflow.svg) |
| [`i2c_master`](peripherals/i2c_master) | - | [hierarchy](peripherals/i2c_master/docs/block_diagram.svg) | [data flow](peripherals/i2c_master/docs/i2c_master_dataflow.svg) |
| [`i2s`](peripherals/i2s) | - | - | [data flow](peripherals/i2s/docs/i2s_dataflow.svg) |
| [`intc`](peripherals/intc) | - | [hierarchy](peripherals/intc/docs/block_diagram.svg) | [data flow](peripherals/intc/docs/intc_dataflow.svg) |
| [`pcie_tl_ep`](peripherals/pcie_tl_ep) | - | [hierarchy](peripherals/pcie_tl_ep/docs/block_diagram.svg) | [data flow](peripherals/pcie_tl_ep/docs/pcie_tl_ep_dataflow.svg) |
| [`quadrature_decoder`](peripherals/quadrature_decoder) | - | [hierarchy](peripherals/quadrature_decoder/docs/block_diagram.svg) | [data flow](peripherals/quadrature_decoder/docs/quadrature_decoder_dataflow.svg) |
| [`sdio_host`](peripherals/sdio_host) | - | [hierarchy](peripherals/sdio_host/docs/block_diagram.svg) | [data flow](peripherals/sdio_host/docs/sdio_host_dataflow.svg) |
| [`spi_flash_ctrl`](peripherals/spi_flash_ctrl) | - | [hierarchy](peripherals/spi_flash_ctrl/docs/block_diagram.svg) | [data flow](peripherals/spi_flash_ctrl/docs/spi_flash_ctrl_dataflow.svg) |
| [`spi_master`](peripherals/spi_master) | - | [hierarchy](peripherals/spi_master/docs/block_diagram.svg) | [data flow](peripherals/spi_master/docs/spi_master_dataflow.svg) |
| [`spi_slave`](peripherals/spi_slave) | - | [hierarchy](peripherals/spi_slave/docs/block_diagram.svg) | [data flow](peripherals/spi_slave/docs/spi_slave_dataflow.svg) |
| [`uart`](peripherals/uart) | - | [hierarchy](peripherals/uart/docs/block_diagram.svg) | [data flow](peripherals/uart/docs/uart_dataflow.svg) |
| [`uart_rx`](peripherals/uart_rx) | - | - | [data flow](peripherals/uart_rx/docs/uart_rx_dataflow.svg) |
| [`uart_tx`](peripherals/uart_tx) | - | - | [data flow](peripherals/uart_tx/docs/uart_tx_dataflow.svg) |
| [`usb_fs_sie`](peripherals/usb_fs_sie) | - | [hierarchy](peripherals/usb_fs_sie/docs/block_diagram.svg) | [data flow](peripherals/usb_fs_sie/docs/usb_fs_sie_dataflow.svg) |

### Scalers

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`axi_checkers`](scalers/axi_checkers) | - | - | [data flow](scalers/axi_checkers/docs/axi_checkers_dataflow.svg) |
| [`axil_regbus`](scalers/axil_regbus) | - | - | [data flow](scalers/axil_regbus/docs/axil_regbus_dataflow.svg) |
| [`axil_split`](scalers/axil_split) | - | - | [data flow](scalers/axil_split/docs/axil_split_dataflow.svg) |
| [`banked_framebuf`](scalers/banked_framebuf) | - | - | [data flow](scalers/banked_framebuf/docs/banked_framebuf_dataflow.svg) |
| [`scaler_anisotropic`](scalers/scaler_anisotropic) | - | [hierarchy](scalers/scaler_anisotropic/docs/block_diagram.svg) | [data flow](scalers/scaler_anisotropic/docs/scaler_anisotropic_dataflow.svg) |
| [`scaler_bicubic`](scalers/scaler_bicubic) | - | [hierarchy](scalers/scaler_bicubic/docs/block_diagram.svg) | [data flow](scalers/scaler_bicubic/docs/scaler_bicubic_dataflow.svg) |
| [`scaler_bilinear`](scalers/scaler_bilinear) | - | [hierarchy](scalers/scaler_bilinear/docs/block_diagram.svg) | [data flow](scalers/scaler_bilinear/docs/scaler_bilinear_dataflow.svg) |
| [`scaler_ctrl`](scalers/scaler_ctrl) | - | - | [data flow](scalers/scaler_ctrl/docs/scaler_ctrl_dataflow.svg) |
| [`scaler_dda`](scalers/scaler_dda) | - | - | [data flow](scalers/scaler_dda/docs/scaler_dda_dataflow.svg) |
| [`scaler_edge_directed`](scalers/scaler_edge_directed) | - | [hierarchy](scalers/scaler_edge_directed/docs/block_diagram.svg) | [data flow](scalers/scaler_edge_directed/docs/scaler_edge_directed_dataflow.svg) |
| [`scaler_lanczos`](scalers/scaler_lanczos) | - | [hierarchy](scalers/scaler_lanczos/docs/block_diagram.svg) | [data flow](scalers/scaler_lanczos/docs/scaler_lanczos_dataflow.svg) |
| [`scaler_mip`](scalers/scaler_mip) | - | [hierarchy](scalers/scaler_mip/docs/block_diagram.svg) | [data flow](scalers/scaler_mip/docs/scaler_mip_dataflow.svg) |
| [`scaler_nearest`](scalers/scaler_nearest) | - | [hierarchy](scalers/scaler_nearest/docs/block_diagram.svg) | [data flow](scalers/scaler_nearest/docs/scaler_nearest_dataflow.svg) |
| [`scaler_polyphase`](scalers/scaler_polyphase) | - | [hierarchy](scalers/scaler_polyphase/docs/block_diagram.svg) | [data flow](scalers/scaler_polyphase/docs/scaler_polyphase_dataflow.svg) |
| [`scaler_trilinear`](scalers/scaler_trilinear) | - | [hierarchy](scalers/scaler_trilinear/docs/block_diagram.svg) | [data flow](scalers/scaler_trilinear/docs/scaler_trilinear_dataflow.svg) |
| [`sharpen_cas`](scalers/sharpen_cas) | - | [hierarchy](scalers/sharpen_cas/docs/block_diagram.svg) | [data flow](scalers/sharpen_cas/docs/sharpen_cas_dataflow.svg) |
| [`spatial_upscaler`](scalers/spatial_upscaler) | - | [hierarchy](scalers/spatial_upscaler/docs/block_diagram.svg) | [data flow](scalers/spatial_upscaler/docs/spatial_upscaler_dataflow.svg) |

### Timing

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`baud_generator`](timing/baud_generator) | - | - | [data flow](timing/baud_generator/docs/baud_generator_dataflow.svg) |
| [`baud_nco`](timing/baud_nco) | - | [hierarchy](timing/baud_nco/docs/block_diagram.svg) | [data flow](timing/baud_nco/docs/baud_nco_dataflow.svg) |
| [`clock_enable`](timing/clock_enable) | - | - | [data flow](timing/clock_enable/docs/clock_enable_dataflow.svg) |
| [`counter`](timing/counter) | - | - | [data flow](timing/counter/docs/counter_dataflow.svg) |
| [`frequency_counter`](timing/frequency_counter) | - | [hierarchy](timing/frequency_counter/docs/block_diagram.svg) | [data flow](timing/frequency_counter/docs/frequency_counter_dataflow.svg) |
| [`interval_timer`](timing/interval_timer) | - | - | [data flow](timing/interval_timer/docs/interval_timer_dataflow.svg) |
| [`nco`](timing/nco) | - | - | [data flow](timing/nco/docs/nco_dataflow.svg) |
| [`pulse_generator`](timing/pulse_generator) | - | - | [data flow](timing/pulse_generator/docs/pulse_generator_dataflow.svg) |
| [`pwm`](timing/pwm) | - | [hierarchy](timing/pwm/docs/block_diagram.svg) | [data flow](timing/pwm/docs/pwm_dataflow.svg) |
| [`rate_limiter`](timing/rate_limiter) | - | - | [data flow](timing/rate_limiter/docs/rate_limiter_dataflow.svg) |
| [`timeout_timer`](timing/timeout_timer) | - | - | [data flow](timing/timeout_timer/docs/timeout_timer_dataflow.svg) |
| [`timestamp_counter`](timing/timestamp_counter) | - | - | [data flow](timing/timestamp_counter/docs/timestamp_counter_dataflow.svg) |
| [`watchdog`](timing/watchdog) | - | [hierarchy](timing/watchdog/docs/block_diagram.svg) | [data flow](timing/watchdog/docs/watchdog_dataflow.svg) |

### Video

| IP | Block / state diagrams | RTL hierarchy | Data flow |
|---|---|---|---|
| [`axis_to_video`](video/axis_to_video) | - | - | [data flow](video/axis_to_video/docs/axis_to_video_dataflow.svg) |
| [`blur_filter`](video/blur_filter) | - | [hierarchy](video/blur_filter/docs/block_diagram.svg) | [data flow](video/blur_filter/docs/blur_filter_dataflow.svg) |
| [`blur_sharpen`](video/blur_sharpen) | - | [hierarchy](video/blur_sharpen/docs/block_diagram.svg) | [data flow](video/blur_sharpen/docs/blur_sharpen_dataflow.svg) |
| [`conv2d_core`](video/conv2d_core) | - | [hierarchy](video/conv2d_core/docs/block_diagram.svg) | [data flow](video/conv2d_core/docs/conv2d_core_dataflow.svg) |
| [`conv2d_filter`](video/conv2d_filter) | - | [hierarchy](video/conv2d_filter/docs/block_diagram.svg) | [data flow](video/conv2d_filter/docs/conv2d_filter_dataflow.svg) |
| [`csi2_raw_unpack`](video/csi2_raw_unpack) | - | - | [data flow](video/csi2_raw_unpack/docs/csi2_raw_unpack_dataflow.svg) |
| [`csi2_rx`](video/csi2_rx) | - | - | [data flow](video/csi2_rx/docs/csi2_rx_dataflow.svg) |
| [`csi2_tx`](video/csi2_tx) | - | - | [data flow](video/csi2_tx/docs/csi2_tx_dataflow.svg) |
| [`dsi_tx`](video/dsi_tx) | - | - | [data flow](video/dsi_tx/docs/dsi_tx_dataflow.svg) |
| [`hdmi_tx`](video/hdmi_tx) | - | - | [data flow](video/hdmi_tx/docs/hdmi_tx_dataflow.svg) |
| [`isp_blc_wb`](video/isp_blc_wb) | - | - | [data flow](video/isp_blc_wb/docs/isp_blc_wb_dataflow.svg) |
| [`isp_ccm`](video/isp_ccm) | - | - | [data flow](video/isp_ccm/docs/isp_ccm_dataflow.svg) |
| [`isp_csc`](video/isp_csc) | - | - | [data flow](video/isp_csc/docs/isp_csc_dataflow.svg) |
| [`isp_demosaic`](video/isp_demosaic) | - | - | [data flow](video/isp_demosaic/docs/isp_demosaic_dataflow.svg) |
| [`isp_dpc`](video/isp_dpc) | - | - | [data flow](video/isp_dpc/docs/isp_dpc_dataflow.svg) |
| [`isp_gamma`](video/isp_gamma) | - | - | [data flow](video/isp_gamma/docs/isp_gamma_dataflow.svg) |
| [`isp_stats`](video/isp_stats) | - | - | [data flow](video/isp_stats/docs/isp_stats_dataflow.svg) |
| [`isp_window`](video/isp_window) | - | - | [data flow](video/isp_window/docs/isp_window_dataflow.svg) |
| [`lvds_serializer`](video/lvds_serializer) | - | - | [data flow](video/lvds_serializer/docs/lvds_serializer_dataflow.svg) |
| [`lvds_tx`](video/lvds_tx) | - | - | [data flow](video/lvds_tx/docs/lvds_tx_dataflow.svg) |
| [`mipi_line_buf`](video/mipi_line_buf) | - | - | [data flow](video/mipi_line_buf/docs/mipi_line_buf_dataflow.svg) |
| [`mipi_tx_engine`](video/mipi_tx_engine) | - | - | [data flow](video/mipi_tx_engine/docs/mipi_tx_engine_dataflow.svg) |
| [`sharpen_filter`](video/sharpen_filter) | - | [hierarchy](video/sharpen_filter/docs/block_diagram.svg) | [data flow](video/sharpen_filter/docs/sharpen_filter_dataflow.svg) |
| [`tmds_encoder`](video/tmds_encoder) | - | - | [data flow](video/tmds_encoder/docs/tmds_encoder_dataflow.svg) |
| [`tmds_serializer`](video/tmds_serializer) | - | - | [data flow](video/tmds_serializer/docs/tmds_serializer_dataflow.svg) |
| [`vid_timing_gen`](video/vid_timing_gen) | - | - | [data flow](video/vid_timing_gen/docs/vid_timing_gen_dataflow.svg) |
| [`video_pipeline`](video/video_pipeline) | - | - | [data flow](video/video_pipeline/docs/video_pipeline_dataflow.svg) |
<!-- diagrams:end -->
