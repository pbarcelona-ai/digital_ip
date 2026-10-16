# Design guidelines

Rules for every module and system in the FPGA Cores 4 U digital IP library. The generation
prompts ([module](MODULE_PROMPT_TEMPLATE.md), [system](SYSTEM_PROMPT_TEMPLATE.md) and every
generated `docs/<name>_prompt.md`) summarise these rules and point here; this file is the
complete version. Where a prompt and this file disagree, the prompt's explicit value wins
(for example a coverage target it lowers on purpose).

## 1. Language and tools

- Synthesizable SystemVerilog-2012, technology independent: no vendor primitives outside
  wrappers; infer RAM, ROM and DSP from behavioural code.
- Every file must compile in iverilog 12+ (`-g2012`), pass Verilator lint (`-Wall`, no
  `UNOPTFLAT`, no latches) and synthesize in Yosys (through sv2v when needed: add the
  `scripts/sv2v` marker file).
- iverilog limits: declare before use; no enum ternaries without casts; no `break` (use a
  flag); no arrays of queues; no `wait` on a function call; no variable declarations inside
  nested loop bodies of static `initial` blocks; no `ref` task arguments.
- Behavioural (simulation-only) models are wrapped so synthesis sees a black box:
  `` `ifdef SYNTHESIS (* blackbox *) module ... `` (see `ip/clock/dpll/src/dpll_dco.sv`).

## 2. Formatting

Enforced by `ip/scripts/sv_format.py` (`--check` reports, without it rewrites; only whitespace
changes, every rewrite is checked token for token):

- **One statement per line.** `a <= b; c <= d;` is two lines; `if (x) y <= 1; else y <= 0;` is
  four lines (`if`, statement, `else`, statement).
- **Instantiations: one parameter per line and one port per line.**

  ```systemverilog
  conv2d_core #(
    .N(N),
    .C(C),
    .CW(CW)
  ) u_stage1 (
    .clk,
    .rst_n,
    .s_axis_tdata(px_d),
    .s_axis_tvalid(px_v)
  );
  ```

  A port-group macro (e.g. `` `PY_AXIL_PORT(S_SYS) ``) counts as one port and gets its own line.
- Two-space indentation, no tabs; `begin` on the line of its `if` / `for` / `always_ff`.
- Every port and every non-obvious signal has a one-line comment.

## 3. File header

Every file starts with the library header: read the template from
[`ip/docs/HEADER_TEMPLATE.txt`](HEADER_TEMPLATE.txt) and fill it in (Filename, Author: FPGA
Cores 4 U, Description with behaviour / register map / clocks / resets / crossings / latency /
resources, Date). The description is the specification: precise enough to write a reference
model from.

## 4. Naming

- Modules and files `lower_snake_case`; one module per file, file named after it.
- Instances `u_<role>`; generate blocks `g_<role>`; parameters `UPPER_CASE`.
- Ports: `_i` / `_o` suffixes for plain inputs / outputs, `s_axis_*` / `m_axis_*`,
  `s_axil_*` / `m_axil_*` for buses, `_n` for active low, `_t` for an output-enable
  (open drain: `_o` is 0, `_t` = 1 releases).
- Clocks `clk` / `<domain>_clk`, resets `rst_n` / `<domain>_rst_n` (or `aresetn` on AXI).

## 5. Clocks, resets and clock-domain crossings

- Every clock domain is documented (name, frequency, source, which logic runs on it).
- **Resets:** one reset per clock domain, synchronous active low inside the domain. An
  asynchronous reset enters a domain only through a reset synchroniser (`reset_sync`:
  asynchronous assertion, synchronous release after 2+ flops of that domain's clock). Reset
  sequencing between domains (e.g. core logic released after the CPU has booted) has a single
  source and is documented.
- **Every signal that crosses a clock boundary uses a clock-domain crossing technique**, and
  the crossing is listed in the file header. Never sample a signal from another clock domain
  directly, and never pass a multi-bit value through independent single-bit synchronisers.

  | Technique | Use for | Library module |
  |-----------|---------|----------------|
  | Two- (or more) flop synchroniser, `async_reg` flops | a single slow level signal (enable, status, interrupt level) | `bit_sync` |
  | Pulse synchroniser (toggle + sync + edge detect) | a one-clock event / pulse | `pulse_sync`, `toggle_sync` |
  | Reset synchroniser (async assert, sync release) | a reset into a domain | `reset_sync`, `reset_ctrl` |
  | Asynchronous FIFO with Gray-coded pointers | a data stream, any rate ratio | `async_fifo`, `axis_async_bridge` |
  | Request / acknowledge handshake (4- or 2-phase) | an occasional multi-bit word, register access | `axi4_lite_cdc`, `clock_domain_bridge` |
  | Multi-cycle path (MCP) formulation: hold data, synchronise a qualifier | a multi-bit value that changes rarely | `cdc_sync_bit` + a held register |
  | Gray-code counter | a counter read in another domain | (inside `async_fifo`) |
  | Glitch-free clock gate / mux | stopping or switching a clock | device BUFGCE / BUFGMUX, `dpll_dco` enables |
  | Related clocks from one PLL, fixed phase | serializers (e.g. 10:1 TMDS) | `clk_gen` outputs sharing one oscillator |

- Constrain every crossing for synthesis / timing (false path or max-delay on the
  synchroniser's first flop) and say so in the constraints file.

## 6. Interfaces

- Data: AXI4-Stream (`tuser` = start of frame, `tlast` = end of line / packet). Honour
  back-pressure; never drop data unless the specification says so (then count it);
  `valid` never depends combinationally on `ready`.
- Control: AXI4-Lite through `ip_axil_regs`; an ID register, an INFO register (build
  parameters); out-of-range accesses return SLVERR. Configuration changes take effect at a
  defined switch-over point (frame / packet start, or a COMMIT write).
- A block that cannot be stalled is documented and protected (FIFO, admission control).

## 7. Verification

- A self-checking testbench per module (`tb/<name>_tb.sv`) that prints `TEST PASSED` or
  `TEST FAILED (n errors)`, with an independent reference model (not a copy of the RTL).
- Test tasks live in `tb/tests/<name>_tests.sv` (`` `included ``), one task per test, named
  `test_<what>`, each listed with a one-line description in the file header. The simulation
  script lists them: `scripts/run_sim.sh --list-tests` (library IP: `make list-tests`).
- Random input gaps (about 25 %) and output back-pressure (about 30 %) on every stream; every
  mode and parameter corner; register readback; configuration changed mid-frame; edge cases;
  protocol checks; a global timeout; a mutation check (break one rule, the test must fail).
- **Code coverage, 100 % by default for every metric** (`make cov`, `ip/scripts/run_cov.sh`):

  | Metric | Default target |
  |--------|----------------|
  | Line (statement) | 100 % |
  | Branch (if / case arms, ternaries) | 100 % |
  | Expression / condition | 100 % |
  | Toggle (every bit 0 to 1 and 1 to 0) | 100 % |
  | FSM state and transition | 100 % |
  | Functional coverage (a cover point / cover property per requirement, mode and corner) | 100 % |
  | Assertions (every SVA property exercised, none failing) | 100 % |

  A target may be lowered only in the prompt, per metric, with the reason. Every uncovered
  item that remains is listed with its justification (unreachable by design, tied-off
  parameter, ...); waivers are reviewed, not silent.

## 8. Deliverables and scripts

- Library IP: `src/`, `tb/` (+ `tb/tests/`, `tb/scripts/build.f`), `scripts/build.f`,
  `Makefile` (`include ../../scripts/ip.mk`), `docs/` (generated diagrams and prompt), and a
  line in `ip/scripts/ips.csv`.
- Systems: `src/configuration.sv`, `src/`, `sw/`, `scripts/build.f`, `scripts/run_sim.sh`
  (with `--list-tests`), `tb/`, `synth/`, `constraints/`, `docs/`, `ci/`, `Makefile`,
  `README.md`.
- Every simulation script documents in its usage header the tests it can run and prints their
  names (`--list-tests`, and at the start of a run).

## 9. Documentation

- Diagrams (Graphviz `.dot` in `docs/`): every block labelled with its library module and
  instance name; arrows from output to input (device inputs: source to input, device outputs:
  logic to destination); no crossing lines (split into several diagrams if needed); every
  clock and reset domain labelled.
- README: purpose, block diagram, clocks and resets, register / address map, how to run each
  test, coverage results, known limits.

## Project guidelines as a CSV file

Project- or customer-specific guidelines can be given as a CSV file and are then added to every
generated prompt (a table of mandatory, optional and unclassified guidelines with their notes):

| Column | Contents |
|--------|----------|
| 1 | the guideline |
| 2 | mandatory: any mark (`x`, `yes`, `1`, ...) sets it; empty, `0`, `no`, `false` or `-` does not |
| 3 | optional: the same marks |
| 4 | notes |

A first row starting with `Guideline` is a header; empty rows and rows starting with `#` are
skipped; Excel's UTF-8 CSV (with a BOM) is accepted. A row marked both mandatory and optional
counts as mandatory; a row marked neither is listed as unclassified (both give a warning).
Example: [`DESIGN_GUIDELINES_EXAMPLE.csv`](DESIGN_GUIDELINES_EXAMPLE.csv).

- `python3 ip/scripts/make_ip_prompts.py --guidelines-csv <file>` (every IP / system / example prompt)
- `python3 ip/scripts/make_system_prompt.py --guidelines-csv <file>` (or the `guidelines_csv` answer)
- Without the option, `ip/docs/DESIGN_GUIDELINES.csv` is used when it exists.
