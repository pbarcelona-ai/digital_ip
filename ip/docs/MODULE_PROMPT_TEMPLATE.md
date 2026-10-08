# Prompt template: generate a library module

A fill-in-the-blanks prompt for asking an AI coding assistant to design,
verify and document a new IP block in the FPGA Cores 4U library's
conventions. It asks for everything a reviewer would want before accepting
a module: the interfaces, a register map, behaviour precise enough for a
bit-exact model, tool constraints, the deliverables and a verification plan.

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

=== 4. Clocks and resets ===
Clocks: <clk only | list each clock, its relationship, and which logic runs on it>
Reset:  synchronous, active-low rst_n (or aresetn), one per clock domain
Clock-domain crossings: <none | which signals cross and with which library synchroniser>

=== 5. Interfaces ===
Every port gets a one-line comment. Use these standard forms:

5a. AXI4-Stream data in / out (s_axis_*, m_axis_*):
    tdata width: <expression, e.g. C*CW>; layout: <e.g. component j in [j*CW +: CW], RGB = {B,G,R}>
    tuser = <start of frame | other>; tlast = <end of line | end of packet>; tkeep: <used | not used>
    Back-pressure: honour tready and never drop data; valid must not depend combinationally on ready.
    Throughput target: <e.g. 1 beat per clock>

5b. AXI4-Lite control (s_axil_*), ADDR_W = <n>, 32-bit data, using ip_axil_regs:
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
- Resource budget: <e.g. at most N DSP48, M RAMB18, ~K LUTs on Xilinx 7-series>
- Timing target: <e.g. 150 MHz on 7-series, logic depth about 10 or less>

=== 8. Deliverables (library layout) ===
ip/<category>/<module_name>/
  src/<module_name>.sv        header: Filename / Author: FPGA Cores 4 U / Description (behaviour,
                              register map, clock, reset, latency, resources) / Date
  tb/<module_name>_tb.sv      self-checking, prints "TEST PASSED" or "TEST FAILED (n errors)"
  scripts/build.f             RTL file list, dependency order (packages first)
  tb/scripts/build.f          testbench file list
  Makefile                    IP := <module_name> / include ../../scripts/ip.mk
  docs/                       generated with `make diagrams`
Also: add "<module_name>,<category>,<top>" to ip/scripts/ips.csv and a section to the category README.

=== 9. Verification requirements ===
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
Pass criteria: `make -C ip/<category>/<module_name> test` passes; Verilator lint clean; `make synth` passes
and reports the resources.

=== 10. Report back ===
Summarize: the files created, the register map, test results (with the mutation result),
the synthesis resources, any changes made to existing IP and why, and known limits.
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

=== 4. Clocks and resets ===
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

=== 8-10 ===
As in the template. The testbench covers all 5 modes against a two-stage conv2d_ref chain,
equal latency in every mode, gaps and back-pressure, custom kernels in both orders (results must
differ), MODE written mid-frame, a 6 x 3 frame, and mutations (stage order swapped; rounding removed).
```
