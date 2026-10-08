# Prompt template: generate a system

A fill-in-the-blanks prompt for asking an AI coding assistant to build a
complete system (a top level that integrates many IP blocks, firmware and a
system testbench) from the FPGA Cores 4U library. It is the system-level
companion of the
[module prompt template](MODULE_PROMPT_TEMPLATE.md), which is used for any new block
the system needs.

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
   and verification depth, then writes the prompt (sections 1-12 below).

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

=== 7. Clocks, resets and performance ===
Clock domains: <name, frequency, source>        Formats: <e.g. 1920x1080p60 RGB888>
Throughput / latency: <...>                      Timing target: <...>
Resource budget: <LUTs / DSP / BRAM or "report">
One reset_sync per domain from one asynchronous reset; crossings only through library
synchronisers (async_fifo, axis_async_bridge, axi4_lite_cdc, pulse_sync, bit_sync, toggle_sync).

=== 8. Control processor and firmware ===
Processor: <py_soc | none (host)>     Firmware: <what it must do at start-up and at run time>
The firmware brings the system up like a product: release external devices from reset, configure
them over I2C / SPI, program every block, enable interrupts, report status, check for errors.

=== 9. Implementation constraints ===
Synthesizable, technology-independent SystemVerilog-2012 (vendor primitives only in wrappers);
iverilog 12+, Verilator lint clean (no loops, no latches), Yosys (sv2v where needed).
AXI4-Stream for data, AXI4-Lite for control; honour back-pressure; a block that cannot be
stalled must be documented and protected. Library file headers on every file.

=== 10. Deliverables ===
digital_ip/<location>/: src/configuration.sv, src/<name>.sv (+ glue), sw/ (firmware),
scripts/build.f + run_sim.sh, tb/ (+ tb/scripts/build.f), synth/run_yosys.sh, constraints/,
docs/ (block diagrams labelled with library module and instance names), ci/run_checked.sh,
Makefile (sim, lint, synth, diagram, ci), README.md, .gitignore.

=== 11. Verification ===
System testbench with board models that decode the real outputs; with a CPU, nothing is
programmed by the testbench (the firmware boots and configures the system); end-to-end
comparison with an independent reference model (state any tolerance and why); every interface
configuration; random gaps and back-pressure; a mutation check; the regressions of any changed
IP still pass.

=== 12. Report back ===
Files created, block diagram, address map, every change to existing IP and why, the decisions
for missing functions, test results (with the mutation check), synthesis utilisation, known
limits and open work.
```
