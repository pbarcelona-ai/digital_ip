#!/usr/bin/env python3
# ***************
# Filename: make_ip_prompts.py
# Author: FPGA Cores 4 U
# Description: Writes a generation prompt for every existing IP, system and
#   example, reverse-engineered from its sources: <dir>/docs/<name>_prompt.md.
#   IP blocks and examples follow ip/docs/MODULE_PROMPT_TEMPLATE.md, systems
#   (image_processing/*) follow ip/docs/SYSTEM_PROMPT_TEMPLATE.md. The content
#   comes from the RTL file header (behaviour, register map, clocks, latency),
#   the module's parameter and port declarations, scripts/build.f (reused IP),
#   the file lists of every other block (where it is used), the testbench
#   header (verification), configuration.sv, firmware and synthesis reports.
# Date: 2026-10-08
# ***************
"""Usage: python3 ip/scripts/make_ip_prompts.py [--only NAME ...] [--dry-run]"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_system_prompt import IP_ROOT, REPO, SYSTEMS_ROOT, discover  # noqa: E402

TODAY = date.today().isoformat()
GEN = "ip/scripts/make_ip_prompts.py"


# ======================================================================= source parsing

def header_block(src: Path) -> tuple[str, str]:
    """(Description text with its layout, whole header text) of a library file."""
    lines = src.read_text(encoding="utf-8", errors="replace").splitlines()
    desc, whole, on = [], [], False
    for line in lines[:400]:
        if not line.lstrip().startswith("//"):
            if whole:
                break
            continue
        body = re.sub(r"^\s*//\s?", "", line)
        if re.match(r"\*{3,}", body.strip()) or re.match(r"(Filename|Author):", body.strip()):
            continue
        if body.strip().startswith("Date:"):
            if desc:
                on = False
            continue
        m = re.match(r"Description:\s*(.*)", body.strip())
        if m:
            on = True
            desc.append(m.group(1))
            whole.append(m.group(1))
            continue
        if on:
            desc.append(body.rstrip())
        whole.append(body.rstrip())
    dedent = lambda ls: "\n".join(l[2:] if l.startswith("  ") else l for l in ls).strip()
    return dedent(desc), dedent(whole)


@dataclass
class Port:
    name: str
    direction: str
    width: str
    comment: str
    group: str
    define: str


@dataclass
class Param:
    name: str
    default: str
    comment: str
    local: bool


@dataclass
class ModuleDecl:
    params: list[Param] = field(default_factory=list)
    ports: list[Port] = field(default_factory=list)


def parse_module(src: Path, top: str, text: str | None = None) -> ModuleDecl:
    text = (text if text is not None else src.read_text(encoding="utf-8", errors="replace")).splitlines()
    decl = ModuleDecl()
    start = next((i for i, l in enumerate(text) if re.match(rf"\s*module\s+{re.escape(top)}\b", l)), None)
    if start is None:
        return decl
    state = "param" if "#(" in text[start] or (start + 1 < len(text) and text[start + 1].strip().startswith("#(")) else "port"
    if state == "port" and "(" not in text[start]:
        state = "pre"
    group, define, last_param = "", "", None
    for raw in text[start + 1:]:
        line = raw.rstrip()
        s = line.strip()
        if re.match(r"^\);", s):
            break
        if not s and state == "port":                   # a blank line ends a port group
            group = ""
            continue
        if state == "pre":
            if s.startswith("#("):
                state = "param"
            elif s.startswith("("):
                state = "port"
            continue
        if state == "param" and re.match(r"^\)\s*\(", s):
            state = "port"
            continue
        m = re.match(r"`(ifdef|ifndef|elsif)\s+(\w+)", s)
        if m:
            define = ("not " if m.group(1) == "ifndef" else "") + m.group(2)
            continue
        if s.startswith("`else"):
            define = ("not " + define) if define and not define.startswith("not ") else define[4:]
            continue
        if s.startswith("`endif"):
            define = ""
            continue
        code, _, comment = s.partition("//")
        code, comment = code.strip(), comment.strip()
        if not code:
            if comment and state == "port":
                group = comment.strip("-= ").strip()
            elif comment and state == "param" and last_param is not None:
                last_param.comment = (last_param.comment + " " + comment).strip()
            continue
        if state == "param":
            m = re.match(r"(parameter|localparam)\s+(?:[\w:]+\s+)*?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*(.+?)\s*,?$", code)
            if m:
                last_param = Param(m.group(2), m.group(3).rstrip(","), comment, m.group(1) == "localparam")
                decl.params.append(last_param)
            continue
        m = re.match(r"(input|output|inout)\b(.*)$", code)
        if not m:
            continue
        rest = m.group(2).rstrip(",").strip()
        dims = re.findall(r"\[[^\]]*\]", rest)
        rest = re.sub(r"\[[^\]]*\]", " ", rest)
        chunks = [c.split() for c in rest.split(",") if c.strip()]
        names = [c[-1] for c in chunks if c]
        width = dims[0] if dims else "1"
        for n in names:
            decl.ports.append(Port(n, m.group(1), width, comment, group, define))
    return decl


def build_list(path: Path) -> list[Path]:
    """Files of a build.f, resolved (relative to the design root or the build.f directory)."""
    if not path.is_file():
        return []
    root = path.parent.parent if path.parent.name == "scripts" else path.parent
    out = []
    for line in path.read_text().splitlines():
        line = line.split("//")[0].strip()
        if not line or line.startswith(("#", "+", "-")):
            continue
        for base in (root, path.parent):
            f = (base / line).resolve()
            if f.is_file():
                out.append(f)
                break
    return out


def owner(f: Path) -> str:
    """The library block a source file belongs to: ip/<cat>/<name>/... -> name."""
    try:
        rel = f.relative_to(IP_ROOT)
        if len(rel.parts) >= 3 and rel.parts[2] in ("src", "tb"):
            return rel.parts[1]
        return "/".join(rel.parts[:2])
    except ValueError:
        try:
            parts = f.relative_to(SYSTEMS_ROOT).parts
            return parts[2] if len(parts) > 3 and parts[1] == "ip" else parts[0]
        except ValueError:
            return f.name


def summary(text: str) -> str:
    """First sentence (two if the first is only a label such as 'Reusable IP.')."""
    d = re.sub(r"\s+", " ", text).strip()
    d = re.sub(r"\s*Version \d+(\.\d+)*\.?", "", d)
    sents = re.findall(r".+?(?<!\be\.g)(?<!\bi\.e)[.!?](?=\s|$)", d) or [d]
    out = sents[0].strip()
    if len(out) < 25 and len(sents) > 1:
        out += " " + sents[1].strip()
    return out[:200]


def file_desc(f: Path) -> str:
    """Summary of a source file's Description."""
    return summary(header_block(f)[0])


def utilisation(name: str) -> str:
    rpt = IP_ROOT / "build" / "yosys" / name / "utilization_flat.rpt"
    if not rpt.is_file():
        return ""
    counts: dict[str, int] = {}
    for line in rpt.read_text(errors="replace").splitlines():
        m = re.match(r"\s*(\d+)\s+(LUT\d|FD\w+|DSP48E1|RAMB\d+E1|RAM\d+\w+|CARRY4)\b", line) or \
            re.match(r"\s*(LUT\d|FD\w+|DSP48E1|RAMB\d+E1|RAM\d+\w+|CARRY4)\s+(\d+)\b", line)
        if m:
            a, b = m.groups()
            k, v = (b, int(a)) if a.isdigit() else (a, int(b))
            counts[k] = v
    if not counts:
        return ""
    lut = sum(v for k, v in counts.items() if k.startswith("LUT"))
    ff = sum(v for k, v in counts.items() if k.startswith("FD"))
    parts = [f"about {lut} LUTs", f"{ff} flip-flops"]
    if counts.get("DSP48E1"):
        parts.append(f"{counts['DSP48E1']} DSP48E1")
    for k in ("RAMB36E1", "RAMB18E1"):
        if counts.get(k):
            parts.append(f"{counts[k]} {k}")
    return "Last Yosys synth_xilinx (7-series) result: " + ", ".join(parts) + ". Stay within about this budget."


# ======================================================================= prompt pieces

def fence(text: str) -> str:
    return "```text\n" + text.strip() + "\n```"


def table(header: list[str], rows: list[list[str]]) -> str:
    esc = lambda c: (c or "-").replace("|", "\\|").replace("\n", " ")
    return "\n".join(["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"] +
                     ["| " + " | ".join(esc(c) for c in r) + " |" for r in rows])


STREAM_RE = re.compile(r"^(?P<p>(?:\w+_)?(?:s|m)_?axis\w*?)_t(?P<sig>data|valid|ready|last|user|keep|strb|id|dest)$")
AXIL_RE = re.compile(r"^(?P<p>(?:\w+_)?[sm]_axil?\w*?)_(aw|w|b|ar|r)(addr|data|strb|valid|ready|resp|prot)$")


def interfaces(decl: ModuleDecl) -> tuple[list[str], list[Port]]:
    """Bundle summaries (AXI4-Lite, AXI4-Stream) and the remaining ports."""
    lite: dict[str, list[Port]] = {}
    stream: dict[str, list[Port]] = {}
    other = []
    for p in decl.ports:
        m = AXIL_RE.match(p.name)
        if m and not STREAM_RE.match(p.name):
            lite.setdefault(m.group("p"), []).append(p)
            continue
        m = STREAM_RE.match(p.name)
        if m:
            stream.setdefault(m.group("p"), []).append(p)
            continue
        other.append(p)
    out = []
    for prefix, ps in lite.items():
        addr = next((p.width for p in ps if p.name.endswith("awaddr")), "?")
        role = "slave" if any(p.name.endswith("awaddr") and p.direction == "input" for p in ps) else "master"
        cond = f" (when `{ps[0].define}`)" if ps[0].define else ""
        out.append(f"- **{prefix}_*** - AXI4-Lite {role}, address {addr}, 32-bit data{cond}.")
    for prefix, ps in stream.items():
        sigs = {re.sub(r".*_t", "", p.name): p for p in ps}
        data = sigs.get("data")
        role = "slave (input)" if data is None or data.direction == "input" else "master (output)"
        extra = ", ".join(f"t{k}" for k in sigs if k not in ("data", "valid", "ready"))
        cmt = "; ".join(f"t{k} = {p.comment}" for k, p in sigs.items() if p.comment)
        cond = f" (when `{ps[0].define}`)" if ps[0].define else ""
        out.append(f"- **{prefix}_t*** - AXI4-Stream {role}, tdata {data.width if data else '-'}"
                   f"{', ' + extra if extra else ''}{cond}{'. ' + cmt if cmt else ''}.")
    return out, other


def port_rows(ports: list[Port]) -> list[list[str]]:
    return [[f"`{p.name}`", p.direction, p.width, p.group, f"`{p.define}`" if p.define else "", p.comment] for p in ports]


def used_by(name: str, users: dict[str, set[str]]) -> str:
    u = sorted(users.get(name, set()) - {name})
    return ", ".join(f"`{x}`" for x in u) if u else "standalone library block"


# ======================================================================= module prompt

def module_prompt(name: str, category: str, ipdir: Path, top: str, src: Path, users: dict[str, set[str]],
                  descs: dict[str, str], extra_sections: str = "", title_note: str = "", library: bool = True) -> str:
    desc, whole = header_block(src)
    decl = parse_module(src, top)
    bundles, others = interfaces(decl)
    clocks = [p.name for p in decl.ports if p.direction == "input" and re.search(r"clk|clock", p.name)]
    resets = [p.name for p in decl.ports if p.direction == "input" and re.search(r"rst|reset", p.name)]
    files = build_list(ipdir / "scripts" / "build.f")
    reuse = []
    for f in files:
        o = owner(f)
        if o != name and f.stem != top:
            reuse.append([f"`{f.stem}`", f"`{o}`", descs.get(o) if o in descs and f.stem in (o, top) else file_desc(f)])
    tb_files = sorted(list((ipdir / "tb").glob("*_tb.sv")) + list((ipdir / "tb").glob("tb_*.sv"))) if (ipdir / "tb").is_dir() else []
    tb_desc = header_block(tb_files[0])[0] if tb_files else ""
    has_py = (ipdir / "tb" / "python").is_dir()
    params = [p for p in decl.params if not p.local]
    derived = [p for p in decl.params if p.local]
    first = summary(desc) if desc else name
    regs = "0x" in whole
    util = utilisation(name)
    sv2v = (ipdir / "scripts" / "sv2v").is_file()

    lines = [
        f"# {name}: generation prompt",
        "",
        f"*Generated by `{GEN}` from the RTL and testbench sources on {TODAY}"
        f"{title_note}. It follows `ip/docs/MODULE_PROMPT_TEMPLATE.md`; edit any field before use.*",
        "",
        "```text",
        "Create a new SystemVerilog IP block for the FPGA Cores 4 U digital IP library.",
        "```",
        "",
        "## 1. Identity",
        "",
        f"- Module name: `{top}`" + (f" (IP directory `{name}`)" if top != name else ""),
        f"- Library category: `{category}`",
        f"- Location: `{ipdir.relative_to(REPO)}/`",
        f"- One-line purpose: {first}",
        "- Version: 1.0.0",
        "",
        "## 2. Context",
        "",
        f"- Where it is used: {used_by(name, users)}.",
        "- Existing IP to reuse (do not duplicate):" + ("" if reuse else " none; self-contained."),
    ]
    if reuse:
        lines += ["", table(["Module", "From", "Description"], reuse)]
    lines += [
        "",
        "## 3. Parameters",
        "",
        table(["Name", "Default", "Meaning / legal range"], [[f"`{p.name}`", f"`{p.default}`", p.comment] for p in params])
        if params else "None.",
        "",
    ]
    if derived:
        lines += ["Derived (localparam): " + ", ".join(f"`{p.name} = {p.default}`" for p in derived) + ".", ""]
    lines += ["Reject illegal values at elaboration with `$error` inside a generate block.", "",
              "## 4. Clocks and resets", "",
              f"- Clocks: {', '.join(f'`{c}`' for c in clocks) or 'none (combinational)'}.",
              f"- Resets: {', '.join(f'`{r}`' for r in resets) or 'none'}.",
              "- Clock and reset behaviour, and any clock-domain crossing, as described in section 6.",
              "",
              "## 5. Interfaces", ""]
    if bundles:
        lines += bundles + [""]
    if others:
        lines += [table(["Port", "Dir", "Width", "Group", "Built when", "Description"], port_rows(others)), ""]
    lines += ["Back-pressure on every stream: honour tready, never drop data unless section 6 says so; "
              "valid must not depend combinationally on ready.", ""]
    if regs:
        lines += ["AXI4-Lite / register map: as listed in the behaviour text in section 6. Out-of-range accesses "
                  "return SLVERR (or DECERR where stated).", ""]
    lines += ["## 6. Function", "",
              "Implement exactly this behaviour (from the reference design's specification):", "",
              fence(whole or desc or "(no header text)"), "",
              "Describe and handle the edge cases, error recovery, latency and configuration-change rules stated above; "
              "where the text is silent, choose the safe option and document it in the file header.", "",
              extra_sections,
              "## 7. Implementation constraints", "",
              "- Synthesizable SystemVerilog-2012, technology independent (no vendor primitives; infer RAM and DSP).",
              "- Must work in iverilog 12+ (`-g2012`), Verilator lint (`-Wall`, no UNOPTFLAT or latches) and Yosys"
              + (" (through sv2v: add the `scripts/sv2v` marker file)." if sv2v else "."),
              "- iverilog limits: declare before use; no enum ternaries without casts; no `break`; no arrays of "
              "queues; no `wait` on function calls; no declarations inside nested loop bodies of static initial blocks.",
              "- No combinational path from a ready input back to a ready output; hoist scratch variables "
              "(no latches); split control and data `always_ff` blocks.",
              f"- Resources: {util or 'report the Yosys utilisation; keep it in line with similar library blocks.'}",
              "",
              "## 8. Deliverables", "",
              "```text",
              f"{ipdir.relative_to(REPO)}/",
              f"  src/{top}.sv" + "".join(f"\n  src/{f.name}" for f in files if owner(f) == name and f.stem != top),
              (f"  tb/{name}_tb.sv          self-checking, prints TEST PASSED / TEST FAILED (n errors)" if library
               else f"  tb/{tb_files[0].name if tb_files else 'tb_' + name + '.sv'}    self-checking testbench"),
              "  scripts/build.f           RTL file list, dependency order (packages first)",
              "  tb/scripts/build.f        testbench file list",
              (f"  Makefile                  IP := {name} / include ../../scripts/ip.mk\n  docs/                     block diagram (make diagrams)"
               if library else "  scripts/run.sh, scripts/run_yosys.sh"),
              "```",
              "",
              (f"Add `{name},{category},{top}` to `ip/scripts/ips.csv` and a line to the category README." if library
               else "Design-local block: keep it in the design's `ip/` directory and add it to the design's file lists."),
              "",
              "## 9. Verification requirements", "",
              "The reference testbench checks the following; the new testbench must cover at least the same:", "",
              fence(tb_desc) if tb_desc else
              (f"- The reference testbench `{tb_files[0].relative_to(ipdir)}` has no description header: read it and "
               "cover at least what it checks." if tb_files else
               f"- The reference design has no dedicated testbench; the block is exercised inside {used_by(name, users)}. "
               "Write a self-checking testbench for it."),
              ""]
    if has_py:
        lines += ["There is also a Python (cocotb) test in `tb/python/`; provide an equivalent.", ""]
    lines += ["Also: an independent reference model (not a copy of the RTL); random input gaps and output "
              "back-pressure on every stream; register readback; edge cases; a mutation check (break one rule, "
              "show the testbench fails).", "",
              (f"Pass criteria: `make -C {ipdir.relative_to(IP_ROOT)} test` passes, Verilator lint clean, `make synth` passes."
               if library else "Pass criteria: the block's `scripts/run.sh` passes, Verilator lint clean, synthesis passes."),
              "",
              "## 10. Report back", "",
              "Files created, register map, test results (with the mutation check), synthesis resources, any "
              "change to existing IP and why, known limits.", ""]
    return "\n".join(l for l in lines if l is not None)


# ======================================================================= system prompt

def system_prompt(name: str, d: Path, users: dict[str, set[str]], descs: dict[str, str]) -> str:
    top_src = d / "src" / f"{name}.sv"
    desc, whole = header_block(top_src)
    decl = parse_module(top_src, name)
    bundles, others = interfaces(decl)
    bf = d / "scripts" / "build.f" if (d / "scripts" / "build.f").is_file() else d / "src" / "build.f"
    files = build_list(bf)
    seen, reuse, local = set(), [], []
    for f in files:
        o = owner(f)
        if f.is_relative_to(d):
            local.append([f"`{f.stem}`", f"`{f.relative_to(d)}`", file_desc(f)])
            continue
        if (o, f.stem) in seen:
            continue
        seen.add((o, f.stem))
        reuse.append([f"`{f.stem}`", f"`{o}`", file_desc(f) or descs.get(o, "")])
    cfg = d / "src" / "configuration.sv"
    features = []
    if cfg.is_file():
        for line in cfg.read_text().splitlines():
            m = re.match(r"//\s+(VP_\w+|[A-Z][A-Z0-9_]+)\s{2,}(.*)", line)
            if m:
                features.append([m.group(1), m.group(2).strip()])
            elif features and re.match(r"//\s{8,}\S", line):          # continuation of the description
                features[-1][1] += " " + line.lstrip("/ ").strip()
            elif not line.startswith("//"):
                pass
        features = [f"- `{k}`: {v}" for k, v in features]
    vendor = sorted({re.sub(r"\s+", " ", l.strip()) for l in whole.splitlines() if re.search(r"vendor|PLL|D-PHY|OBUFDS|board wrapper", l, re.I)})
    sw = sorted((d / "sw").glob("*.py")) if (d / "sw").is_dir() else []
    tbs = sorted(list((d / "tb").glob("*_tb.sv")) + list((d / "tb_verilog").glob("tb_*.sv")) if (d / "tb").is_dir() or (d / "tb_verilog").is_dir() else [])
    tb_text = "\n\n".join(f"{t.relative_to(d)}:\n{header_block(t)[0]}" for t in tbs if header_block(t)[0])
    py_tests = sorted((d / "tb").glob("test_*.py")) if (d / "tb").is_dir() else []
    tree = sorted(p.relative_to(d).as_posix() + "/" for p in d.iterdir() if p.is_dir() and not p.name.startswith((".", "build", "__")))
    util = ""
    rpt = d / "build" / "synth_run.out"
    if rpt.is_file():
        tail = rpt.read_text(errors="replace")
        if "SYNTH PASS" in tail:
            nums = dict((m.group(1), int(m.group(2))) for m in re.finditer(r"^\s+(\w+)\s+(\d+)\s*$", tail, re.M))
            lut = sum(v for k, v in nums.items() if k.startswith("LUT"))
            util = f"Last Yosys result: about {lut} LUTs, {nums.get('DSP48E1', 0)} DSP48E1, {nums.get('RAMB36E1', 0)} RAMB36E1, {nums.get('RAMB18E1', 0)} RAMB18E1."
    first = summary(desc) if desc else name

    L = [f"# {name}: system generation prompt", "",
         f"*Generated by `{GEN}` from the design sources on {TODAY}. It follows `ip/docs/SYSTEM_PROMPT_TEMPLATE.md`; edit any field before use.*",
         "", "```text",
         "Create a complete FPGA / ASIC system for the FPGA Cores 4 U digital IP library, built from the",
         "existing library IP wherever possible.", "```", "",
         "## 1. Identity and goal", "",
         f"- Top module: `{name}`", f"- Location: `digital_ip/{d.relative_to(REPO)}/`",
         f"- Purpose: {first}", "- Target: not selected (technology independent); vendor parts outside the top.", "",
         "## 2. Features", ""]
    L += features or ["- As described in section 6."]
    L += ["", "## 3. External interfaces", ""]
    L += bundles + [""] if bundles else []
    if others:
        L += [table(["Port", "Dir", "Width", "Group", "Built when", "Description"], port_rows(others)), ""]
    L += ["Analog / high-speed PHYs are vendor parts outside the technology-independent top: expose their parallel "
          "interface as ports and document the board wrapper.", "",
          "## 4. Existing IP to reuse", "",
          table(["Module", "From", "Description"], reuse) if reuse else "(none)", "",
          "Use them unchanged where possible; any change must be backward compatible (default off, existing tests still pass) and reported.", "",
          "## 5. Functions not in the library and how to provide them", ""]
    if local:
        L += ["Blocks written for this system (in the design directory, new in a regenerated design; "
              "each can be specified with the module prompt template):", "",
              table(["Module", "File", "Description"], local), ""]
    if vendor:
        L += ["External / vendor parts named in the reference design:", "", fence("\n".join(vendor)), ""]
    L += ["If another needed function is missing, stop and ask which option to use (new / vendor / third-party / stub / drop).", "",
          "## 6. Architecture and behaviour", "",
          "Implement this behaviour (from the reference design's specification):", "",
          fence(whole or desc), "",
          "## 7. Clocks, resets and performance", "",
          f"- Clocks: {', '.join(f'`{p.name}`' for p in decl.ports if p.direction == 'input' and re.search(r'clk', p.name)) or 'see section 6'}.",
          f"- Resets: {', '.join(f'`{p.name}`' for p in decl.ports if p.direction == 'input' and re.search(r'rst|reset', p.name)) or 'see section 6'}; one `reset_sync` per domain.",
          "- Crossings only through library synchronisers.",
          f"- Resources: {util or 'report the Yosys utilisation.'}", "",
          "## 8. Control processor and firmware", ""]
    if sw:
        for f in sw:
            doc = re.search(r'"""(.*?)"""', f.read_text(), re.S)
            L += [f"Firmware `{f.relative_to(d)}`:", "", fence(doc.group(1) if doc else f.name), ""]
    else:
        L += ["No on-chip processor in the reference design: an external host programs the registers (section 6).", ""]
    L += ["## 9. Implementation constraints", "",
          "Synthesizable, technology-independent SystemVerilog-2012; iverilog 12+, Verilator lint clean, Yosys "
          "(sv2v where needed); AXI4-Stream for data, AXI4-Lite for control; honour back-pressure; library file headers.", "",
          "## 10. Deliverables", "", "```text", f"digital_ip/{d.relative_to(REPO)}/"] + [f"  {t}" for t in tree] + \
         ["  Makefile, README.md, .gitignore", "```", "",
          "## 11. Verification", "",
          "The reference design is verified as follows; cover at least the same:", "",
          fence(tb_text) if tb_text else "- (no testbench header found)", ""]
    if py_tests:
        L += ["Python (cocotb) tests: " + ", ".join(f"`{p.name}`" for p in py_tests) + ".", ""]
    L += ["## 12. Report back", "",
          "Files created, block diagram, address map, every change to existing IP and why, decisions for missing "
          "functions, test results (with a mutation check), synthesis utilisation, known limits.", ""]
    return "\n".join(L)


# ======================================================================= examples

def regmap_section(json_path: Path) -> str:
    spec = json.loads(json_path.read_text())
    rows = []
    for i, r in enumerate(spec.get("registers", [])):
        fields = "; ".join(f"{f['name']}[{f['bit']}] {f.get('desc', '')}".strip() for f in r.get("fields", []))
        rows.append([f"0x{i * 4:02X}", r["name"], r.get("access", "RW"), r.get("reset", "0"), r.get("desc", ""), fields])
    return ("### Register map (from `" + json_path.name + "`)\n\n" +
            table(["Offset", "Name", "Access", "Reset", "Description", "Fields"], rows) +
            "\n\nThe block is generated, not hand-written: write the JSON above and run "
            f"`python3 ip/scripts/regmap_gen.py {json_path.relative_to(REPO).as_posix()}`, which also emits the "
            "C header and Markdown documentation. Extend the generator rather than editing its output.\n\n")


# ======================================================================= main

def main() -> None:
    ap = argparse.ArgumentParser(description="Write <name>_prompt.md for every IP, system and example.")
    ap.add_argument("--only", nargs="*", help="limit to these names")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    mods = discover()
    descs = {m.name: m.description for m in mods.values()}
    tops = {}
    csv_path = IP_ROOT / "scripts" / "ips.csv"
    for row in csv.reader(l for l in csv_path.read_text().splitlines() if l and not l.startswith("#")):
        if len(row) >= 3:
            tops[row[0].strip()] = row[2].strip()

    # where each block is used: every other block's file list
    users: dict[str, set[str]] = {}
    for m in mods.values():
        for bf in (m.path / "scripts" / "build.f", m.path / "src" / "build.f"):
            for f in build_list(bf):
                users.setdefault(owner(f), set()).add(m.name)

    written = []
    for m in sorted(mods.values(), key=lambda m: (m.category, m.name)):
        if args.only and m.name not in args.only:
            continue
        if m.system:
            text = system_prompt(m.name, m.path, users, descs)
        else:
            top = tops.get(m.name, m.name)
            src = m.path / "src" / f"{top}.sv"
            if not src.is_file():
                src, top = m.path / "src" / f"{m.name}.sv", m.name
            if not src.is_file():                       # sources shared with another IP: find them in build.f
                top = tops.get(m.name, m.name)
                src = next((f for f in build_list(m.path / "scripts" / "build.f") if f.stem == top), Path("-"))
            if not src.is_file():
                print(f"skip {m.name}: no top source")
                continue
            text = module_prompt(m.name, m.category, m.path, top, src, users, descs)
        out = m.path / "docs" / f"{m.name}_prompt.md"
        written.append(out)
        if not args.dry_run:
            out.parent.mkdir(exist_ok=True)
            out.write_text(text, encoding="utf-8")

    # design-local IP inside each system: image_processing/<system>/ip/<name>/src
    for sysdir in sorted(p for p in SYSTEMS_ROOT.iterdir() if (p / "ip").is_dir()):
        for sub in sorted(p for p in (sysdir / "ip").iterdir() if (p / "src").is_dir()):
            if args.only and sub.name not in args.only and sysdir.name not in args.only:
                continue
            srcs = sorted((sub / "src").glob("*.sv"))
            src = sub / "src" / f"{sub.name}.sv"
            if not src.is_file():
                src = next((f for f in srcs if f.stem.startswith(sub.name)), srcs[0] if srcs else Path("-"))
            if not src.is_file():
                continue
            text = module_prompt(sub.name, f"{sysdir.name} (design-local IP)", sub, src.stem, src, users, descs,
                                 title_note=f" (part of `{sysdir.name}`)", library=False)
            out = sub / "docs" / f"{sub.name}_prompt.md"
            written.append(out)
            if not args.dry_run:
                out.parent.mkdir(exist_ok=True)
                out.write_text(text, encoding="utf-8")

    # examples: ip/examples/<example>/<module>.sv (+ .json register description)
    for ex in sorted(p for p in (IP_ROOT / "examples").iterdir() if p.is_dir()):
        for src in sorted(ex.glob("*.sv")):
            name = src.stem
            if args.only and name not in args.only and ex.name not in args.only:
                continue
            js = src.with_suffix(".json")
            extra = regmap_section(js) if js.is_file() else ""
            text = module_prompt(name, "examples", ex, name, src, users, descs, extra_sections=extra,
                                 title_note=f" (example `{ex.name}`)")
            out = ex / "docs" / f"{name}_prompt.md"
            written.append(out)
            if not args.dry_run:
                out.parent.mkdir(exist_ok=True)
                out.write_text(text, encoding="utf-8")

    for w in written:
        print(w.relative_to(REPO))
    print(f"{len(written)} prompt files{' (dry run)' if args.dry_run else ''}")


if __name__ == "__main__":
    main()
