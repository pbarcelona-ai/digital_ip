# Prompt template: generate a system

A fill-in-the-blanks prompt for asking an AI coding assistant to build a
complete system (a top level that integrates many IP blocks, firmware and a
system testbench) from the FPGA Cores 4U library. It is the system-level
companion of the
[module prompt template](MODULE_PROMPT_TEMPLATE.md), which is used for any new block
the system needs. Both prompts point to two external files the generator must
read: the file header template [`HEADER_TEMPLATE.txt`](HEADER_TEMPLATE.txt) and
the complete design guidelines [`DESIGN_GUIDELINES.md`](DESIGN_GUIDELINES.md).

## The easy way: the prompt builder

```sh
python3 ip/scripts/make_system_prompt.py                  # interactive
python3 ip/scripts/make_system_prompt.py --list           # existing IP, by category
python3 ip/scripts/make_system_prompt.py --features       # features and what they need
python3 ip/scripts/make_system_prompt.py --answers a.json --defaults -o my_prompt.md
```

The builder:

1. asks for the system's name, purpose, target and design directory;
2. offers a menu of features (camera inputs, video processing, frame buffer,
   display outputs, Ethernet, USB, PCIe, CAN, audio, DSP, security, CPU and
   low-speed peripherals) plus free-text "other functions";
3. works out the **functions** those features need and proposes **existing
   modules** for them: one per function, alternatives listed. It discovers them
   from `ip/scripts/ips.csv`, every `ip/<category>/<name>/src` and the designs in
   `image_processing/`. You can add modules (`--list` shows them all) or remove
   proposals;
4. for every function that **no existing module provides**, and for external
   parts such as PHYs, PLLs and DDR controllers, asks how to provide it:

   | Option | Meaning |
   |--------|---------|
   | new | create a new library module (with MODULE_PROMPT_TEMPLATE.md) |
   | vendor | vendor IP behind a technology-independent wrapper |
   | thirdparty | a named third-party / open-source core |
   | stub | simulation stub with the real interface; the real block comes later |
   | drop | leave it out |
   | existing:<module> | use an existing alternative instead |

   It then asks for details (vendor IP name, licence, key requirements). A
   module you name that is not in the library is treated the same way;
5. asks for formats, throughput, clocks, CPU, firmware, budget, timing
   and verification depth, then writes the prompt (sections 1-15 below:
   including clock-domain crossing techniques, the file header template, the
   design guidelines, the tools for each step, the test list and code
   coverage targets, 100 % by default).

`--save-answers FILE` records every answer, so the same prompt can be
regenerated (or edited and regenerated) with `--answers FILE`.

## The template (by hand)

```text
Create a complete FPGA / ASIC system for the FPGA Cores 4 U digital IP library, built from the
existing library IP wherever possible.

=== 1. Identity and goal ===
Top module: <name>          Location: digital_ip/<image_processing>/<name>/
Purpose:    <what the system does, for whom>
Target:     <device / board, or "not selected (technology independent)">

=== 2. Features ===
- <feature 1, e.g. MIPI CSI-2 camera input>
- <feature 2>
- <other functions not covered by the library>

=== 3. External interfaces ===
| Interface | Standard / pins | Direction | Rate / format | Notes |
|-----------|-----------------|-----------|---------------|-------|
| <MIPI CSI-2 RX> | <2 data lanes + clock, D-PHY> | in | <RAW10, 800 Mb/s/lane> | <vendor D-PHY> |
For every interface: its top-level ports, clock, `define and the module that drives it.
Analog / high-speed PHYs are vendor parts outside the technology-independent top: expose their
parallel (PPI / SerDes / PHY) interface as ports and document the board wrapper.

=== 4. Existing IP to reuse ===   (user-specified: list everything you want used)
| Module | Category | Role in this system | Alternatives |
|--------|----------|---------------------|--------------|
| <csi2_rx> | <video> | <camera packet layer> | <-> |
Use them unchanged where possible; any change must be backward compatible (default off, the
existing tests still pass) and reported.

=== 5. Functions not in the library and how to provide them ===
| Function | Needed by | Decision (new / vendor / thirdparty / stub / drop) | Details |
|----------|-----------|----------------------------------------------------|---------|
| <DDR controller> | <frame buffer> | <vendor> | <MIG DDR4, AXI4 256-bit> |
| <OSD overlay> | <menus> | <new> | <AXI4-Stream in/out, 2-bit palette plane> |
new: follow MODULE_PROMPT_TEMPLATE.md; deliver it with its own testbench before integrating.
vendor / thirdparty: wrapper with the stated interface, black box in synthesis, behavioural model
in simulation. stub: real interface, behavioural model only, listed as open work.
If you find another function that is needed and missing, STOP and ask which option to use.

=== 6. Architecture ===
- Data path from inputs to outputs with the module names, stream format on every arrow
  (width, tuser / tlast meaning) and every clock-domain crossing.
- Control plane: one AXI4-Lite register space; propose the address map (table) and interrupts.
- src/configuration.sv: a `define per optional block / interface (compiled first); excluded blocks
  have no ports or logic; a BUILD_CFG register reports what was built.
- Configuration changes take effect at the next frame / packet start.
- Where data can be dropped (rate mismatch, overflow), how it is counted, how the system recovers
  without a reset.

=== 7. Clocks, resets, clock-domain crossings and performance ===
Clock domains: <name, frequency, source>        Formats: <e.g. 1920x1080p60 RGB888>
Throughput / latency: <...>                      Timing target: <...>
Resource budget: <LUTs / DSP / BRAM or "report">
Resets: one reset_sync per domain; reset sequencing between domains has a single, documented
source (e.g. core logic released by the CPU after boot).
Every clock, reset and signal boundary uses a clock-domain crossing technique; list every
crossing (signal, width, rate, technique). Never sample another domain's signal directly,
never pass a multi-bit value through independent single-bit synchronisers. Example techniques:
  | Technique                                       | Use for                                 | Library module                     |
  |-------------------------------------------------|-----------------------------------------|------------------------------------|
  | Two- (or more) flop synchroniser (async_reg)    | single slow level (enable, status, IRQ) | bit_sync                           |
  | Pulse synchroniser (toggle, sync, edge detect)  | one-clock event / pulse                 | pulse_sync, toggle_sync            |
  | Reset synchroniser (async assert, sync release) | a reset entering a clock domain         | reset_sync, reset_ctrl             |
  | Asynchronous FIFO, Gray-coded pointers          | data stream at any rate ratio           | async_fifo, axis_async_bridge      |
  | Request / acknowledge handshake (2- / 4-phase)  | occasional multi-bit word, registers    | axi4_lite_cdc, clock_domain_bridge |
  | Multi-cycle path (hold data, sync a qualifier)  | multi-bit value that changes rarely     | cdc_sync_bit + held register       |
  | Gray-code counter                               | counter read in another domain          | inside async_fifo                  |
  | Glitch-free clock gate / mux                    | stopping or switching a clock           | device BUFGCE / BUFGMUX, clk_gen   |
  | Related clocks from one PLL (fixed phase)       | serializers (10:1 TMDS, 7:1 LVDS)       | clk_gen outputs of one oscillator  |
Constrain every crossing (false path / max delay on the synchroniser's first flop).

=== 8. Control processor and firmware ===
Processor: <py_soc | none (host)>     Firmware: <what it must do at start-up and at run time>
The firmware brings the system up like a product: release external devices from reset, configure
them over I2C / SPI, program every block, enable interrupts, report status, check for errors.

=== 9. Implementation constraints ===
Synthesizable, technology-independent SystemVerilog-2012 (vendor primitives only in wrappers);
iverilog 12+, Verilator lint clean (no loops, no latches), Yosys (sv2v where needed).
AXI4-Stream for data, AXI4-Lite for control; honour back-pressure; a block that cannot be
stalled must be documented and protected.
One statement per line; instantiations with one parameter per line in #( ... ) and one port
per line (a port-group macro is one port on its own line); check with
`python3 ip/scripts/sv_format.py --check <files>`.

=== 10. File header ===
Read the file header template from <header template file, default ip/docs/HEADER_TEMPLATE.txt>
and start every file you create (RTL, testbench, test tasks, firmware, scripts, file lists,
Makefile) with that header, filled in: Filename / Author: FPGA Cores 4 U / Description / Date.

=== 11. Guidelines ===
Follow the design guidelines in <guidelines file, default ip/docs/DESIGN_GUIDELINES.md> (the
complete rules; this prompt wins where it sets a value explicitly). In short: technology-
independent SystemVerilog-2012; one statement per line, one parameter and one port per line;
library naming; one reset per domain and every crossing through a CDC technique; AXI4-Stream /
AXI4-Lite with back-pressure; firmware brings the system up like a product; named test_<what>
tasks and 100 % code coverage; diagrams with module and instance names, arrows from output to
input, no crossing lines, every clock and reset domain labelled.
<project-specific guidelines, if any>

=== 12. Tools ===
Use these tools for each step (selected in ip/.tools; keep every script working with them):
  | Step                     | Tool                                                 | How it is run                                |
  |--------------------------|------------------------------------------------------|----------------------------------------------|
  | Simulation               | Icarus Verilog (iverilog -g2012, vvp)                | make sim / scripts/run_sim.sh                |
  | Fast system simulation   | ideal PLL clocks (DPLL_IDEAL)                        | scripts/run_sim.sh --ideal-pll               |
  | Python (cocotb) tests    | cocotb on Verilator                                  | make python-test / tb/scripts/run.py         |
  | Lint                     | Verilator (--lint-only -Wall)                        | make lint                                    |
  | Waveform viewing         | Surfer (VCD)                                         | make wave / run_sim.sh --wave                |
  | Code coverage            | Verilator --coverage, verilator_coverage, cov_report | make cov / ip/scripts/run_cov.sh             |
  | Formatting               | ip/scripts/sv_format.py                              | --check before delivery                      |
  | Firmware (py_soc)        | Python 3 + ip/cpu/py_core/tools/pyc.py               | run by scripts/run_sim.sh                    |
  | Synthesis                | Yosys (Xilinx 7-series flow, sv2v)                   | make synth (or Synplify: SYNTHESIS)          |
  | Place and route (option) | Vivado                                               | PLACE_ROUTE in ip/.tools, once a board is set|
  | Diagrams                 | Graphviz (dot)                                       | make diagram                                 |
  | Test list                | ip/scripts/list_tests.py                             | make list-tests / run_sim.sh --list-tests    |
<other tools, if any>

=== 13. Deliverables ===
digital_ip/<location>/: src/configuration.sv, src/<name>.sv (+ glue), sw/ (firmware),
scripts/build.f + run_sim.sh (with --list-tests, and the test names in its usage header),
tb/ (+ tb/tests/<name>_tests.sv, tb/scripts/build.f), synth/run_yosys.sh, constraints/,
docs/ (block, clock and reset diagrams labelled with library module and instance names),
ci/run_checked.sh, Makefile (sim, list-tests, lint, cov, synth, diagram, ci), README.md,
.gitignore.

=== 14. Verification ===
System testbench with board models that decode the real outputs; with a CPU, nothing is
programmed by the testbench (the firmware boots and configures the system); end-to-end
comparison with an independent reference model (state any tolerance and why); every interface
configuration; random gaps and back-pressure; a mutation check; the regressions of any changed
IP still pass.
Named tests: one task per test in tb/tests/<name>_tests.sv, named test_<what>, listed in its
header; `scripts/run_sim.sh --list-tests` prints them and every run prints them at its start:
  | Test          | Checks |
  |---------------|--------|
  | test_<what>   | <...>  |
Code coverage (make cov); every target is 100 % by default, lower one only here, per metric,
with the reason; list every uncovered item with its justification:
  | Metric                                                  | Target |
  |---------------------------------------------------------|--------|
  | Line (statement)                                        | 100 %  |
  | Branch (if / case arms, ternaries)                      | 100 %  |
  | Expression / condition                                  | 100 %  |
  | Toggle (every bit 0->1 and 1->0)                        | 100 %  |
  | FSM state and transition                                | 100 %  |
  | Functional (cover point per requirement, mode, corner)  | 100 %  |
  | Assertions (every SVA property exercised, none failing) | 100 %  |

=== 15. Report back ===
Files created, block, clock and reset diagrams, address map, every change to existing IP and
why, the decisions for missing functions, the test list with results (with the mutation
check), coverage per metric (and every waiver), synthesis utilisation, known limits and open
work.
```
