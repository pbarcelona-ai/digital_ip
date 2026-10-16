# Prompt template: generate a library module

A fill-in-the-blanks prompt for asking an AI coding assistant to design,
verify and document a new IP block in the FPGA Cores 4U library's
conventions. It asks for everything a reviewer would want before accepting
a module: the interfaces, a register map, behaviour precise enough for a
bit-exact model, clocks / resets / clock-domain crossings, code layout,
the file header (read from [`HEADER_TEMPLATE.txt`](HEADER_TEMPLATE.txt)),
the design guidelines (summarised here, complete in
[`DESIGN_GUIDELINES.md`](DESIGN_GUIDELINES.md)), the tools for each step,
the deliverables, a verification plan with named tests and code coverage
(100 % by default).

Copy the template and replace every `<...>` field; the text inside each
field is a hint. Part 2 is the template filled in for `blur_sharpen`, a
two-stage blur and sharpen filter for AXI4-Stream video, as a worked
example.

---

## Part 1: Template

```text
Create a new SystemVerilog IP block for the FPGA Cores 4 U digital IP library.

=== 1. Identity ===
Module name:      <module_name>
Library category: <video | bus | cdc | cpu | peripherals | fifo | timing | scalers | ...>
Location:         ip/<category>/<module_name>/
One-line purpose: <what it does, in one sentence>
Version:          1.0.0

=== 2. Context ===
Where it is used:   <the upstream and downstream blocks, e.g. "after isp_csc in video_pipeline">
Existing IP to reuse (do not duplicate): <e.g. isp_window, ip_axil_regs, ip_axis_fifo, async_fifo, pulse_sync>
Existing IP it must stay compatible with: <modules, register maps or stream formats>

=== 3. Parameters ===
| Name | Default | Legal range | Meaning |
|------|---------|-------------|---------|
| <P1> | <..>    | <..>        | <..>    |
Reject illegal values at elaboration with $error inside a generate block.

=== 4. Clocks, resets and clock-domain crossings ===
Clocks: <clk only | list each clock: name, frequency, source, relationship, which logic runs on it>
Resets: synchronous, active-low rst_n (or aresetn), one per clock domain; an asynchronous reset
  enters a domain only through a reset synchroniser (asynchronous assert, synchronous release).
Clock-domain crossings: <none | each signal that crosses, its width, rate and the technique used>
Every clock, reset and signal boundary uses a clock-domain crossing technique, listed in the file
header; never sample another domain's signal directly, never pass a multi-bit value through
independent single-bit synchronisers. Example techniques:
  | Technique                                      | Use for                                 | Library module                        |
  |------------------------------------------------|-----------------------------------------|---------------------------------------|
  | Two- (or more) flop synchroniser (async_reg)   | single slow level (enable, status, IRQ) | bit_sync                              |
  | Pulse synchroniser (toggle, sync, edge detect) | one-clock event / pulse                 | pulse_sync, toggle_sync               |
  | Reset synchroniser (async assert, sync release)| a reset entering a clock domain         | reset_sync, reset_ctrl                |
  | Asynchronous FIFO, Gray-coded pointers         | data stream at any rate ratio           | async_fifo, axis_async_bridge         |
  | Request / acknowledge handshake (2- / 4-phase) | occasional multi-bit word, registers    | axi4_lite_cdc, clock_domain_bridge    |
  | Multi-cycle path (hold data, sync a qualifier) | multi-bit value that changes rarely     | cdc_sync_bit + held register          |
  | Gray-code counter                              | counter read in another domain          | inside async_fifo                     |
  | Glitch-free clock gate / mux                   | stopping or switching a clock           | device BUFGCE / BUFGMUX, clk_gen      |
  | Related clocks from one PLL (fixed phase)      | serializers (10:1 TMDS, 7:1 LVDS)       | clk_gen outputs of one oscillator     |
Constrain every crossing (false path / max delay on the synchroniser's first flop).

=== 5. Interfaces ===
Every port gets a one-line comment. Use these standard forms:

5a. AXI4-Stream data in / out (s_axis_*, m_axis_*):
    tdata width: <expression, e.g. C*CW>; layout: <e.g. component j in [j*CW +: CW], RGB = {B,G,R}>
    tuser = <start of frame | other>; tlast = <end of line | end of packet>; tkeep: <used | not used>
    Back-pressure: honour tready and never drop data; valid must not depend combinationally on ready.
    Throughput target: <e.g. 1 beat per clock>
    Interface: AXI4-Stream ports follow axis_if (ip/shared/src/interfaces/axis_if.sv,
    modports master / slave / monitor): discrete ports, with a comment line above the group,
    e.g. // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24

5b. AXI4-Lite control (s_axil_*), ADDR_W = <n>, 32-bit data, using ip_axil_regs:
    Interface: AXI4-Lite ports follow axil_if (ip/shared/src/interfaces/axil_if.sv,
    modports master / slave): discrete ports, with a comment line above the group,
    e.g. // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
    (Icarus cannot drive interface-array members; Yosys reads interfaces only via sv2v.)
    | Offset | Name | Access | Reset | Fields |
    |--------|------|--------|-------|--------|
    | 0x000  | ID   | RO     | "<4 ASCII chars>" | |
    | 0x004  | CTRL | RW     | <..>  | <bit fields> |
    | ...    |      |        |       |        |
    | 0x0xx  | INFO | RO     |       | build parameters |
    When do new values take effect: <immediately | at the next frame start | on a COMMIT write>
    Out-of-range accesses return SLVERR.

5c. Other ports: <interrupts (level or pulse), status outputs, external pins with direction and
    open-drain _o/_t convention, memory interfaces>

=== 6. Function ===
Describe the behaviour precisely enough to write a bit-exact model:
- Algorithm / equations: <formula including rounding, saturation and signedness>
- Operating modes: <table: mode value, behaviour>
- Edge cases: <frame borders, minimum and maximum sizes, empty input, overflow>
- Error and recovery behaviour: <early or late SOF, short frames, FIFO overflow, bus errors, and what is counted>
- Latency: <fixed or variable; must it be the same in every mode?>
- Mode or configuration changes: <never split a frame or packet; describe the switch-over point>

=== 7. Implementation constraints ===
- Synthesizable SystemVerilog-2012, technology independent (no vendor primitives; infer RAM and DSP).
- Must parse in: iverilog 12+ (-g2012), Verilator lint (-Wall, no UNOPTFLAT or latches), Yosys
  (add a scripts/sv2v marker file if Yosys needs sv2v).
- iverilog restrictions to respect: declare before use; no enum ternaries without casts; no `break`
  (use flags); no arrays of queues; no `wait` on function calls; no variable declarations inside
  nested loop bodies of static initial blocks.
- No combinational path from any ready input back to the same block's ready output.
- Hoist scratch variables with defaults (no latches); split control and data always_ff blocks.
- One statement per line (`a <= b; c <= d;` is two lines; `if (x) y <= 1; else y <= 0;` is four).
- Instantiations: one parameter per line in #( ... ) and one port per line, closing with
  `) u_name (` and `);` at the instance's indentation; a port-group macro is one port on its own line.
  Check with `python3 ip/scripts/sv_format.py --check <files>` before delivery.
- Resource budget: <e.g. at most N DSP48, M RAMB18, ~K LUTs on Xilinx 7-series>
- Timing target: <e.g. 150 MHz on 7-series, logic depth about 10 or less>

=== 8. File header ===
Read the file header template from <header template file, default ip/docs/HEADER_TEMPLATE.txt>
and start every file you create (RTL, testbench, test tasks, scripts, file lists, Makefile)
with that header, filled in: Filename / Author: FPGA Cores 4 U / Description / Date. In RTL the
Description is the specification (behaviour, register map, parameters, clocks, resets,
clock-domain crossings, latency, resources, errors); in a testbench it says what is checked;
a test-task file lists every task with a one-line description.

=== 9. Guidelines ===
Follow the design guidelines in <guidelines file, default ip/docs/DESIGN_GUIDELINES.md> (the
complete rules; this prompt wins where it sets a value explicitly). In short:
- Synthesizable, technology-independent SystemVerilog-2012; behavioural models behind
  `ifdef SYNTHESIS black boxes; iverilog / Verilator / Yosys clean.
- Layout: one statement per line; one parameter and one port per line in instantiations;
  two-space indent; a comment on every port.
- Naming: lower_snake_case modules and files, u_ instances, g_ generate blocks, UPPER_CASE
  parameters, _i / _o / _n / _t port suffixes, s_axis_ / m_axis_ / s_axil_ buses.
- Clocks and resets per domain; every crossing through a CDC technique (section 4).
- AXI4-Stream data with back-pressure; AXI4-Lite control (ID / INFO, SLVERR out of range);
  defined switch-over points for configuration changes.
- Self-checking testbench, independent model, named test_<what> tasks, 100 % code coverage.
- Diagrams: module and instance names, arrows from output to input, no crossing lines,
  every clock and reset domain labelled.
<project-specific guidelines, if any>

=== 10. Tools ===
Use these tools for each step (selected in ip/.tools; keep every script working with them):
  | Step                     | Tool                                                 | How it is run                                     |
  |--------------------------|------------------------------------------------------|---------------------------------------------------|
  | Simulation               | Icarus Verilog (iverilog -g2012, vvp)                | make test / scripts/run_sim.sh (or VCS, ModelSim, |
  |                          |                                                      | Questa: SIMULATOR in ip/.tools)                   |
  | Python (cocotb) tests    | cocotb on Verilator                                  | make python-test                                  |
  | Lint                     | Verilator (--lint-only -Wall)                        | run_sim.sh --lint                                 |
  | Waveform viewing         | Surfer (VCD)                                         | make wave / run_sim.sh --wave                     |
  | Code coverage            | Verilator --coverage, verilator_coverage, cov_report | make cov / ip/scripts/run_cov.sh                  |
  | Formatting               | ip/scripts/sv_format.py                              | --check before delivery                           |
  | Synthesis                | Yosys (Xilinx 7-series flow, sv2v where needed)      | make synth (or Synplify: SYNTHESIS)               |
  | Place and route (option) | Vivado                                               | PLACE_ROUTE in ip/.tools, once a device is chosen |
  | Diagrams                 | Graphviz (dot)                                       | make diagrams                                     |
  | Test list                | ip/scripts/list_tests.py                             | make list-tests / run_sim.sh <ip> --list-tests    |
<other tools, if any>

=== 11. Deliverables (library layout) ===
ip/<category>/<module_name>/
  src/<module_name>.sv        file header from section 8 (the Description is the specification)
  tb/<module_name>_tb.sv      self-checking, prints "TEST PASSED" or "TEST FAILED (n errors)"
  tb/tests/<module_name>_tests.sv  one task per test, named test_<what>, listed in its header
  scripts/build.f             RTL file list, dependency order (packages first)
  tb/scripts/build.f          testbench file list
  Makefile                    IP := <module_name> / include ../../scripts/ip.mk
  docs/                       generated with `make diagrams`
Also: add "<module_name>,<category>,<top>" to ip/scripts/ips.csv and a section to the category README.
`make list-tests` (run_sim.sh <ip> --list-tests) must print every test with its description.

=== 12. Verification requirements ===
Testbench (reuse ip/shared/tb/lib/axil_bfm.sv and the category's tb library):
- An independent reference model (not a copy of the RTL); compare every output beat.
- Register readback: ID, INFO, reset values, sign extension.
- Every mode and parameter corner: <list>.
- Random input gaps (about 25%) and output back-pressure (about 30%).
- Configuration changed mid-frame or mid-packet: applies only at the defined switch-over point.
- Edge cases: minimum and maximum sizes, borders, saturation at both ends.
- Latency checks if latency is specified.
- Protocol checks: tuser and tlast positions, no lost or extra beats, a global timeout.
- Mutation check: deliberately break one rule and confirm the testbench fails (report this).
Named tests: one task per test in tb/tests/<module_name>_tests.sv, named test_<what>:
  | Test          | Checks |
  |---------------|--------|
  | test_<what>   | <...>  |
Code coverage (make cov / ip/scripts/run_cov.sh); every target is 100 % by default, lower one only
here, per metric, with the reason; list every uncovered item with its justification:
  | Metric                                                  | Target |
  |---------------------------------------------------------|--------|
  | Line (statement)                                        | 100 %  |
  | Branch (if / case arms, ternaries)                      | 100 %  |
  | Expression / condition                                  | 100 %  |
  | Toggle (every bit 0->1 and 1->0)                        | 100 %  |
  | FSM state and transition                                | 100 %  |
  | Functional (cover point per requirement, mode, corner)  | 100 %  |
  | Assertions (every SVA property exercised, none failing) | 100 %  |
Pass criteria: `make -C ip/<category>/<module_name> test` passes; every coverage target met;
Verilator lint clean; sv_format.py --check clean; `make synth` passes and reports the resources.

=== 13. Report back ===
Summarize: the files created, the register map, the test list (make list-tests) with results
(and the mutation result), the coverage per metric (and every waiver), the synthesis resources,
any changes made to existing IP and why, and known limits.
```

---

## Part 2: Worked example (`blur_sharpen`)

```text
Create a new SystemVerilog IP block for the FPGA Cores 4 U digital IP library.

=== 1. Identity ===
Module name: blur_sharpen          Category: video          Location: ip/video/blur_sharpen/
Purpose: blur and sharpen filter pair for AXI4-Stream video with four selectable orders.

=== 2. Context ===
Used after vision_system in video_processor's insert loop (24-bit RGB, pix_clk).
Reuse: isp_window (N x N window, line buffers, borders) and ip_axil_regs. Build a reusable
conv2d_core (isp_window + MAC) and a programmable conv2d_filter; blur_filter and
sharpen_filter are conv2d_filter with different reset kernels. Kernels go in conv2d_pkg.

=== 3. Parameters ===
N (5; 3 or 5) kernel size | C (3) components | CW (8) component width | COEF_W (12) signed
coefficient width | MAX_W (2048) longest line | BORDER (0 clamp, 1 mirror) | AMOUNT (1)
sharpening strength | RESET_W / RESET_H (1920 / 1080) reset frame size

=== 4. Clocks, resets and clock-domain crossings ===
clk only; synchronous active-low rst_n; no crossings.

=== 5. Interfaces ===
5a. s_axis / m_axis: tdata C*CW bits, component j in [j*CW +: CW]; tuser = SOF, tlast = EOL;
    full back-pressure; 1 pixel per clock (plus isp_window's R idle cycles per line).
5b. AXI4-Lite, ADDR_W = 9:
    0x000 ID RO "BLSH" | 0x004 MODE [2:0] | 0x008 FRAME_SIZE [15:0] W [31:16] H |
    0x00C BLUR_SHIFT | 0x010 SHARP_SHIFT | 0x014 STATUS RO [2:0] mode, [31:16] frames out |
    0x018 INFO RO | 0x040+4i BLUR_K[i] | 0x0C0+4i SHARP_K[i] (signed; reads sign-extended)
    MODE, FRAME_SIZE, kernels and shifts take effect at the next frame start.

=== 6. Function ===
Each stage: out = clamp((sum(K[i]*p[i]) + 2^(shift-1)) >>> shift, 0, 2^CW-1), per component.
Two stages always in line; an unused stage runs the identity kernel, so latency is identical:
  MODE 0 blur / identity | 1 sharpen / identity | 2 sharpen / blur | 3 blur / sharpen | 4-7 identity / identity
Reset kernels: binomial blur [1 4 6 4 1]^2/256; unsharp mask (1+a)I - a*blur, shift 8.
Mode changes never split a frame; stage 2 uses the settings of the frame it is filtering.
Minimum frame (N+1)/2 x (N+1)/2.

=== 7. Constraints ===
As in the template; budget at most 75 DSP48 per 5 x 5 RGB stage.

=== 8-11 ===
As in the template (ip/docs/HEADER_TEMPLATE.txt, ip/docs/DESIGN_GUIDELINES.md, default tools).

=== 12. Verification requirements ===
Tests: test_modes (all 5 modes against a two-stage conv2d_ref chain), test_latency (equal in
every mode), test_flow (gaps and back-pressure), test_custom_kernels (both orders, results must
differ), test_mode_midframe (MODE written mid-frame), test_small_frame (6 x 3), plus mutations
(stage order swapped; rounding removed). Coverage: 100 % on every metric.

=== 13 ===
As in the template.
```
