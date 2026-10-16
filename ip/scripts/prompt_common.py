#!/usr/bin/env python3
# ***************
# Filename: prompt_common.py
# Author: FPGA Cores 4 U
# Description: Prompt sections shared by the generation-prompt builders
#   (make_ip_prompts.py for every IP / system / example prompt,
#   make_system_prompt.py for new systems), so every prompt states the same
#   rules: implementation formatting (one statement per line, one parameter
#   and one port per line in instantiations), the file header template
#   (read from ip/docs/HEADER_TEMPLATE.txt), clocks / resets / clock-domain
#   crossing techniques, the design guidelines (summary here, complete in
#   ip/docs/DESIGN_GUIDELINES.md, plus an optional guidelines CSV: column 1
#   guideline, 2 mandatory, 3 optional, 4 notes; read_guidelines_csv), the
#   tools for every step, code coverage
#   targets (100 % by default) and the tests a simulation script can run
#   (ip/scripts/list_tests.py). Each function returns Markdown lines.
# Date: 2026-10-11
# ***************
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

HEADER_FILE = "ip/docs/HEADER_TEMPLATE.txt"
GUIDELINES_FILE = "ip/docs/DESIGN_GUIDELINES.md"
# Guidelines CSV used when none is given on the command line, if it exists (see read_guidelines_csv)
GUIDELINES_CSV = "ip/docs/DESIGN_GUIDELINES.csv"
REPO_ROOT = Path(__file__).resolve().parents[2]       # digital_ip/
# The guidelines CSV the prompt builders put into every prompt (None: no CSV section); set by their main()
guidelines_csv: str | None = None

# Code coverage metrics and their default targets (percent)
COVERAGE = [
    ("Line (statement)", 100),
    ("Branch (if / case arms, ternaries)", 100),
    ("Expression / condition", 100),
    ("Toggle (every bit 0->1 and 1->0)", 100),
    ("FSM state and transition", 100),
    ("Functional (a cover point / cover property per requirement, mode and corner)", 100),
    ("Assertions (every SVA property exercised, none failing)", 100),
]


def table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("-" * (len(h) + 2) for h in header) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def formatting_constraints() -> list[str]:
    """Implementation-constraint bullets on code layout (enforced by ip/scripts/sv_format.py)."""
    return [
        "- One statement per line (`a <= b; c <= d;` is two lines; `if (x) y <= 1; else y <= 0;` is four).",
        "- Instantiations: one parameter per line in `#( ... )` and one port per line, closing with "
        "`) u_name (` and `);` at the instance's indentation; a port-group macro is one port on its own line.",
        "- Check with `python3 ip/scripts/sv_format.py --check <files>` (it can also rewrite: whitespace only, "
        "token-checked).",
    ]


def header_section(path: str = HEADER_FILE) -> list[str]:
    return [
        f"Read the file header template from `{path}` and start every file you create (RTL, testbench, "
        "test tasks, scripts, file lists, Makefile) with that header, filled in: Filename, Author: FPGA Cores 4 U, "
        "Description, Date. In RTL the Description is the specification (behaviour, register map, parameters, "
        "clocks, resets, clock-domain crossings, latency, resources, errors); in testbenches it says what is "
        "checked; test-task files list every task with a one-line description (the test list scripts use it).",
        "",
        f"Header template file: `{path}`   (replace with your own template file if needed)",
    ]


CDC_ROWS = [
    ["Two- (or more) flop synchroniser (`async_reg`)", "single slow level signal (enable, status, IRQ level)", "`bit_sync`"],
    ["Pulse synchroniser (toggle, sync, edge detect)", "one-clock event / pulse", "`pulse_sync`, `toggle_sync`"],
    ["Reset synchroniser (async assert, sync release)", "a reset entering a clock domain", "`reset_sync`, `reset_ctrl`"],
    ["Asynchronous FIFO with Gray-coded pointers", "data stream at any rate ratio", "`async_fifo`, `axis_async_bridge`"],
    ["Request / acknowledge handshake (2- or 4-phase)", "occasional multi-bit word, register access", "`axi4_lite_cdc`, `clock_domain_bridge`"],
    ["Multi-cycle path formulation (hold data, sync a qualifier)", "multi-bit value that changes rarely", "`cdc_sync_bit` + held register"],
    ["Gray-code counter", "counter value read in another domain", "inside `async_fifo`"],
    ["Glitch-free clock gate / mux", "stopping or switching a clock", "device BUFGCE / BUFGMUX, `clk_gen` enables"],
    ["Related clocks from one PLL (fixed phase)", "serializers, e.g. 10:1 TMDS, 7:1 LVDS", "`clk_gen` outputs of one oscillator"],
]


def cdc_section() -> list[str]:
    return [
        "- Every clock domain: name, frequency, source, the logic on it. Every reset: one per domain, synchronous "
        "active low inside the domain, entering the domain only through a reset synchroniser (asynchronous "
        "assertion, synchronous release); reset sequencing between domains has a single, documented source.",
        "- Every clock, reset and signal boundary uses a clock-domain crossing technique, listed in the file "
        "header. Never sample another domain's signal directly; never pass a multi-bit value through independent "
        "single-bit synchronisers. Example techniques:",
        "",
        table(["Technique", "Use for", "Library module"], CDC_ROWS),
        "",
        "- Constrain every crossing (false path / max delay on the synchroniser's first flop) and document it.",
    ]


@dataclass
class Guideline:
    text: str                                       # column 1: the guideline
    mandatory: bool                                 # column 2: marked mandatory
    optional: bool                                  # column 3: marked optional
    notes: str                                      # column 4: notes
    line: int                                       # line in the CSV file


FALSE_FLAGS = {"", "0", "n", "no", "false", "f", "-", "none"}


def flag(cell: str) -> bool:
    """A mandatory / optional cell is set by any mark (x, yes, y, 1, true, a tick ...), not by "", 0, no, false, -."""
    return cell.strip().lower() not in FALSE_FLAGS


def resolve(path: str | Path) -> Path:
    """A file as given (relative to the current directory), else relative to the repository root."""
    p = Path(path).expanduser()
    return p if p.is_file() or p.is_absolute() else (REPO_ROOT / p if (REPO_ROOT / p).is_file() else p)


def read_guidelines_csv(path: str | Path) -> list[Guideline]:
    """Guidelines from a CSV file: column 1 guideline, column 2 mandatory, column 3 optional, column 4 notes.
    Mandatory / optional are marks (see flag). A first row whose first cell is "guideline" (any case, plural
    too) is a header; empty rows and rows starting with # are skipped; missing cells are empty; a UTF-8
    BOM (Excel) is accepted. A row marked both mandatory and optional counts as mandatory; a row with
    neither is unclassified. Warnings go to stderr."""
    f = resolve(path)
    rows: list[Guideline] = []
    with f.open(encoding="utf-8-sig", newline="") as fh:
        for n, row in enumerate(csv.reader(fh), 1):
            cells = [c.strip() for c in row] + [""] * (4 - len(row))
            if not any(cells) or cells[0].startswith("#"):
                continue
            if not rows and n == 1 and cells[0].lower() in ("guideline", "guidelines"):
                continue
            if not cells[0]:
                print(f"{f}:{n}: warning: no guideline text, row skipped", file=sys.stderr)
                continue
            g = Guideline(cells[0], flag(cells[1]), flag(cells[2]), cells[3], n)
            if g.mandatory and g.optional:
                print(f"{f}:{n}: warning: marked mandatory and optional, taken as mandatory", file=sys.stderr)
            elif not g.mandatory and not g.optional:
                print(f"{f}:{n}: warning: marked neither mandatory nor optional (unclassified)", file=sys.stderr)
            if len(row) > 4 and any(c.strip() for c in row[4:]):
                print(f"{f}:{n}: warning: cells after column 4 ignored", file=sys.stderr)
            rows.append(g)
    return rows


def md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", "<br>")


def guidelines_csv_section(path: str | Path) -> list[str]:
    """Markdown for a guidelines CSV: mandatory, optional and (if any) unclassified guidelines, with notes."""
    rows = read_guidelines_csv(path)
    groups = [("Mandatory (must be met; a deviation needs a stated reason)", [g for g in rows if g.mandatory]),
              ("Optional (recommended; apply where they fit)", [g for g in rows if g.optional and not g.mandatory]),
              ("Unclassified (neither column marked in the file)", [g for g in rows if not g.mandatory and not g.optional])]
    out = [f"Project guidelines from `{path}` ({len(rows)} guidelines: "
           f"{len(groups[0][1])} mandatory, {len(groups[1][1])} optional"
           + (f", {len(groups[2][1])} unclassified" if groups[2][1] else "") + "):", ""]
    for title, items in groups:
        if not items:
            continue
        out += [f"**{title}**", "", table(["#", "Guideline", "Notes"],
                                         [[str(i), md_cell(g.text), md_cell(g.notes) or "-"]
                                          for i, g in enumerate(items, 1)]), ""]
    return out


def guidelines_section(path: str = GUIDELINES_FILE, csv_path: str | Path | None = None) -> list[str]:
    """The guidelines summary; plus the guidelines CSV (csv_path, else the builder's guidelines_csv) when set."""
    csv_path = csv_path if csv_path is not None else guidelines_csv
    extra = ["", *guidelines_csv_section(csv_path)] if csv_path else []
    return [
        f"Follow the design guidelines in `{path}` (complete rules; this prompt wins where it sets a value "
        "explicitly). In short:",
        "",
        "- Synthesizable, technology-independent SystemVerilog-2012; behavioural models behind "
        "`` `ifdef SYNTHESIS `` black boxes; iverilog / Verilator / Yosys clean.",
        "- Layout: one statement per line; one parameter and one port per line in instantiations; two-space "
        "indent; a comment on every port.",
        "- Naming: `lower_snake_case` modules and files, `u_` instances, `g_` generate blocks, `UPPER_CASE` "
        "parameters, `_i` / `_o` / `_n` / `_t` port suffixes, `s_axis_` / `m_axis_` / `s_axil_` buses.",
        "- Clocks and resets per domain, every crossing through a CDC technique (see the clocks section).",
        "- AXI4-Stream data with back-pressure, AXI4-Lite control (ID / INFO registers, SLVERR out of range), "
        "defined switch-over points for configuration changes.",
        "- Self-checking testbench with an independent model, named `test_<what>` tasks in "
        "`tb/tests/<name>_tests.sv`, gaps and back-pressure, a mutation check, 100 % code coverage.",
        "- Diagrams: module and instance names, arrows from output to input, no crossing lines, every clock and "
        "reset domain labelled.",
        "",
        f"Guidelines file: `{path}`   (replace with your own guidelines file if needed)",
        *extra,
    ]


def default_guidelines_csv(given: str | None) -> str | None:
    """The guidelines CSV to use: the one given (must exist), else GUIDELINES_CSV when it exists, else None."""
    if given:
        if not resolve(given).is_file():
            sys.exit(f"guidelines CSV not found: {given}")
        return given
    return GUIDELINES_CSV if resolve(GUIDELINES_CSV).is_file() else None


TOOL_ROWS = [
    ["Simulation", "Icarus Verilog (`iverilog -g2012`, `vvp`)", "`make test` / `scripts/run_sim.sh`; "
     "alternatives VCS, ModelSim, Questa (`SIMULATOR` in `ip/.tools`)"],
    ["Python (cocotb) tests", "cocotb on Verilator", "`make python-test` (`PYTHON_SIMULATOR`)"],
    ["Lint", "Verilator (`--lint-only -Wall`)", "`run_sim.sh --lint` (systems: `make lint`)"],
    ["Waveform viewing", "Surfer (VCD)", "`make wave` / `run_sim.sh --wave` (`--vcd` only dumps)"],
    ["Code coverage", "Verilator `--coverage` + `verilator_coverage`, `ip/tools/cov/cov_report.py`",
     "`make cov` / `ip/scripts/run_cov.sh` (LCOV `coverage.info`; vendor simulators: native coverage)"],
    ["Formatting", "`ip/scripts/sv_format.py`", "`--check` before delivery"],
    ["Synthesis", "Yosys (Xilinx 7-series flow, sv2v where needed)", "`make synth`; alternative Synplify (`SYNTHESIS`)"],
    ["Place and route (optional)", "Vivado", "`PLACE_ROUTE` in `ip/.tools`, once a device is chosen"],
    ["Diagrams", "Graphviz (`dot`)", "`make diagram` / `make diagrams`"],
    ["Firmware (py_soc)", "Python 3 + `ip/cpu/py_core/tools/pyc.py`", "run by `scripts/run_sim.sh`"],
    ["Test list", "`ip/scripts/list_tests.py`", "`run_sim.sh --list-tests` / `make list-tests`"],
    ["Prompts and docs", "`make_ip_prompts.py`, `gen_docs.py`, `make_block_diagrams.py`", "regenerate after a change"],
]


def tools_section() -> list[str]:
    return [
        "Use these tools for each step (the selection lives in `ip/.tools`; keep every script working with "
        "the default tools):",
        "",
        table(["Step", "Tool", "How it is run"], TOOL_ROWS),
    ]


def coverage_section(targets: dict | None = None) -> list[str]:
    t = {name: pct for name, pct in COVERAGE}
    if targets:
        t.update(targets)
    return [
        "Code coverage (`make cov`, `ip/scripts/run_cov.sh`): every target is 100 % by default. A target may be "
        "lowered only here, per metric, with the reason; every item left uncovered is listed with its "
        "justification (unreachable by design, tied-off parameter, ...).",
        "",
        table(["Metric", "Target"], [[k, f"{v} %"] for k, v in t.items()]),
    ]


def tests_section(d: Path | None, run_cmd: str) -> list[str]:
    """The tests the simulation script can run (from the design's test files), and how to list them."""
    lines = [
        f"Every simulation script names the tests it can run: `{run_cmd} --list-tests` prints them (and every "
        "run prints them at its start). Put each test in its own `test_<what>` task in `tb/tests/<name>_tests.sv`, "
        "listed with a one-line description in that file's header.",
    ]
    if d is not None:
        try:
            from list_tests import tests_for
        except ImportError:
            return lines
        tests = tests_for(d)
        if tests:
            lines += ["", "Tests of the reference design (the new design must provide at least these):", "",
                      table(["Testbench", "Test", "Description"],
                            [[f"`{tb}`", f"`{n}`", s.replace("|", "/")] for tb, n, s in tests])]
    return lines
