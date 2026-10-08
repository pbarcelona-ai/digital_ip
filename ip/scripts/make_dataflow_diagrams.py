#!/usr/bin/env python3
# ***************
# Filename: make_dataflow_diagrams.py
# Author: FPGA Cores 4 U
# Description: Data-flow diagram generator for every IP, system and example.
#   For each top module it reads the RTL and draws the top-level ports (inputs
#   left, outputs right), every sub-module instance (module type + instance
#   name), the module's own logic, and an edge for every signal from its
#   driver to its loads, labelled with the signal names from the source.
#   Port directions of instances come from the instantiated modules' own
#   declarations, so the arrows follow the data. AXI4-Lite / AXI4-Stream
#   signal groups are shown as one bundle (prefix_*). Writes
#   <dir>/docs/<name>_dataflow.dot and .svg (Graphviz dot).
# Date: 2026-10-08
# ***************
"""Usage: python3 ip/scripts/make_dataflow_diagrams.py [--only NAME ...] [--no-svg]"""
from __future__ import annotations

import argparse
import csv
import html
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_system_prompt import IP_ROOT, REPO, SYSTEMS_ROOT, discover  # noqa: E402
from make_ip_prompts import build_list, parse_module  # noqa: E402

KEYWORDS = set("""
always always_ff always_comb always_latch assign begin end if else case casez casex endcase default for foreach
while do repeat forever return break continue function endfunction task endtask automatic static logic wire reg bit
byte int integer longint shortint real signed unsigned input output inout module endmodule parameter localparam
genvar generate endgenerate posedge negedge or and not typedef enum struct packed union import export package
endpackage initial final unique priority const var void string inside with modport interface endinterface
""".split())

STREAM_RE = re.compile(r"^((?:\w+_)?(?:s|m)_?axis\w*?)_t(data|valid|ready|last|user|keep|strb|id|dest)$")
AXIL_RE = re.compile(r"^((?:\w+_)?[sm]_axil?\w*?)_(aw|w|b|ar|r)(addr|data|strb|valid|ready|resp|prot)$")
SDRAM_RE = re.compile(r"^(sdram)_\w+$")
# any name with "axi" before the channel suffix (m_axil_*, s_axi_*, m_ext_axil_*, dma_axi_*): which end is
# the master comes from the direction of valid, not from the name
AXI_RE = re.compile(r"^(\w*?axil?\w*?)_(aw|w|b|ar|r)"
                    r"(id|addr|len|size|burst|lock|cache|prot|qos|region|user|data|strb|last|valid|ready|resp)$")
SHORT_STREAM_RE = re.compile(r"^((?:\w+_)?[sm])_t(data|valid|ready|last|user|keep)$")    # ip_axis_fifo style


ANY_STREAM_RE = re.compile(r"^(\w*?axis\w*?)_t(data|valid|ready|last|user|keep|strb|id|dest)$")


def bus_info(name: str) -> tuple[str, str, str] | None:
    """(prefix, protocol family, member) of a protocol-bus port, else None."""
    m = STREAM_RE.match(name) or ANY_STREAM_RE.match(name) or SHORT_STREAM_RE.match(name)
    if m:
        return m.group(1), "AXI4-Stream", m.group(2)
    m = AXI_RE.match(name)
    if m:
        return m.group(1), ("AXI4-Lite" if "axil" in m.group(1) else "AXI4"), m.group(2) + m.group(3)
    return None


CLOCK_RE = re.compile(r"(^|_)(a?clk|clock)(_[a-z0-9]+)?$", re.I)       # clk, pix_clk, clk_i, ser_clk
RESET_RE = re.compile(r"(^|_)a?(rst|reset)(_?n|_b|_i|_ni)?$|resetn$|rstn$", re.I)   # rst_n, aresetn, sys_rst_n


PORT_CLOCK_RE = re.compile(r"(^|_)[a-z]?(clk|clock)(_[a-z0-9]+)?$", re.I)    # also wclk, rclk, aclk on ports


def is_clock_or_reset(name: str, ports: dict) -> bool:
    """Clocks and resets reach almost every block: listed in the title instead of drawn. Ports may use a
    one-letter clock prefix (wclk, rclk); internal nets must match exactly (sclk_hi is data)."""
    clock = PORT_CLOCK_RE if name in ports else CLOCK_RE
    return bool(clock.search(name) or RESET_RE.search(name)) and not STREAM_RE.match(name) and not AXIL_RE.match(name)


def blank(m: re.Match) -> str:
    """Replace a match by spaces, keeping its newlines (line numbers stay valid)."""
    return re.sub(r"[^\n]", " ", m.group(0))


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', text)


def preprocess(text: str, defines: set[str]) -> str:
    """Keep only the active `ifdef / `ifndef / `elsif / `else branches (also inside one line) and record
    `define. Every input line gives one output line, so line numbers stay valid."""
    out, stack = [], []                                     # stack of (active, taken)
    directive = re.compile(r"`(ifdef|ifndef|elsif)\s+(\w+)|`(else|endif)\b|`define\s+(\w+)[^\n]*")
    for line in text.splitlines():
        kept, pos = [], 0
        for m in directive.finditer(line):
            if all(a for a, _ in stack):
                kept.append(line[pos:m.start()])
            pos = m.end()
            kind = m.group(1) or m.group(3)
            if m.group(4):
                if all(a for a, _ in stack):
                    defines.add(m.group(4))
            elif kind in ("ifdef", "ifndef"):
                parent = all(a for a, _ in stack)
                cond = (m.group(2) in defines) == (kind == "ifdef")
                stack.append((parent and cond, cond))
            elif kind == "elsif" and stack:
                _, taken = stack.pop()
                parent = all(a for a, _ in stack)
                cond = (not taken) and m.group(2) in defines
                stack.append((parent and cond, taken or cond))
            elif kind == "else" and stack:
                _, taken = stack.pop()
                parent = all(a for a, _ in stack)
                stack.append((parent and not taken, True))
            elif kind == "endif" and stack:
                stack.pop()
        if all(a for a, _ in stack):
            kept.append(line[pos:])
        out.append("".join(kept))
    return "\n".join(out)


def design_defines(build_files: list[Path]) -> set[str]:
    """Defines set by the configuration files of a file list (configuration.sv ...)."""
    defines: set[str] = set()
    for f in build_files:
        if f.name == "configuration.sv" or f.suffix == ".svh":
            preprocess(f.read_text(errors="replace"), defines)
    return defines


def bundle(name: str) -> str:
    """Group key of a signal: the AXI / SDRAM interface prefix, else the name itself."""
    b = bus_info(name)
    if b:
        return b[0] + "_*"
    for rx in (STREAM_RE, AXIL_RE, SDRAM_RE):
        m = rx.match(name)
        if m:
            return m.group(1) + "_*"
    return name


# ======================================================================= module index

@dataclass
class ModInfo:
    name: str
    file: Path
    ports: dict[str, str] = field(default_factory=dict)      # port -> input / output / inout


def index_modules() -> dict[str, ModInfo]:
    idx: dict[str, ModInfo] = {}
    files = list(IP_ROOT.glob("*/*/src/*.sv")) + list(IP_ROOT.glob("examples/*/*.sv")) + \
        list(IP_ROOT.glob("shared/src/**/*.sv")) + list(SYSTEMS_ROOT.glob("*/src/*.sv")) + \
        list(SYSTEMS_ROOT.glob("*/ip/*/src/*.sv"))
    for f in files:
        if "build" in f.parts:
            continue
        for m in re.finditer(r"^\s*module\s+(\w+)", f.read_text(errors="replace"), re.M):
            if m.group(1) not in idx:
                info = ModInfo(m.group(1), f)
                info.ports = {p.name: p.direction for p in parse_module(f, m.group(1)).ports}
                idx[m.group(1)] = info
    return idx


# ======================================================================= one module

@dataclass
class Instance:
    module: str
    name: str
    conns: list[tuple[str, list[str]]]                     # (port, signals in the expression)


def module_body(src: Path, top: str, text: str | None = None) -> str:
    text = strip_comments(text if text is not None else src.read_text(errors="replace"))
    m = re.search(rf"\bmodule\s+{re.escape(top)}\b", text)
    if not m:
        return ""
    end = text.find("endmodule", m.end())
    body = text[m.end(): end if end > 0 else len(text)]
    hdr_end = re.search(r"\)\s*;", body)                    # end of the port list
    return body[hdr_end.end():] if hdr_end else body


def body_first_line(src: Path, top: str, text: str) -> int:
    """Source line number at which module_body() starts."""
    full = strip_comments(text)
    m = re.search(rf"\bmodule\s+{re.escape(top)}\b", full)
    if not m:
        return 1
    h = re.search(r"\)\s*;", full[m.end():])
    return full[:m.end() + (h.end() if h else 0)].count("\n") + 1


def balanced(text: str, start: int) -> tuple[str, int]:
    """Text inside the parentheses that open at text[start] == '('."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i + 1
    return text[start + 1:], len(text)


def identifiers(expr: str, signals: set[str]) -> list[str]:
    out = []
    for tok in re.findall(r"(?<![\w$'.])([A-Za-z_]\w*)", expr):
        if tok in signals and tok not in out:
            out.append(tok)
    return out


def find_instances(body: str, idx: dict[str, ModInfo], signals: set[str]) -> tuple[list[Instance], str]:
    insts, rest, pos = [], [], 0
    rx = re.compile(r"\b([A-Za-z_]\w*)\s*(#\s*\()?")
    i = 0
    while True:
        m = rx.search(body, i)
        if not m:
            break
        mod = m.group(1)
        if mod not in idx or mod in KEYWORDS:
            i = m.end(1)
            continue
        j = m.end()
        if m.group(2):                                         # parameter override list
            _, j = balanced(body, j - 1)
        n = re.match(r"\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*\(", body[j:])
        if not n:
            i = m.end(1)
            continue
        inst = n.group(1)
        conns_text, k = balanced(body, j + n.end() - 1)
        conns: list[tuple[str, list[str]]] = []
        if re.search(r"\.\*", conns_text):                    # .* : every port connects to the same name
            conns += [(p, [p]) for p in idx[mod].ports if p in signals]
        for c in re.finditer(r"\.(\w+)\s*(\()?", conns_text):
            port = c.group(1)
            if c.group(2):
                expr, _ = balanced(conns_text, c.end() - 1)
                conns.append((port, identifiers(expr, signals)))
            else:
                conns.append((port, [port] if port in signals else []))
        insts.append(Instance(mod, inst, conns))
        rest.append(body[pos:m.start()])
        rest.append(re.sub(r"[^\n]", " ", body[m.start():k]))     # keep line numbers
        pos = i = k
    rest.append(body[pos:])
    return insts, "".join(rest)


def without_constants(body: str) -> str:
    """Drop typedefs, parameters and functions: their names are constants or types, not signals."""
    body = re.sub(r"\bfunction\b.*?\bendfunction\b", blank, body, flags=re.S)
    body = re.sub(r"\btask\b.*?\bendtask\b", blank, body, flags=re.S)
    body = re.sub(r"\btypedef\b[^;]*?\{[^{}]*\}[^;]*;", blank, body, flags=re.S)
    body = re.sub(r"\btypedef\b[^;]*;", blank, body)
    return re.sub(r"\b(?:localparam|parameter|const)\b[^;]*;", blank, body)


def declared_signals(body: str, ports: list[str]) -> set[str]:
    sigs = set(ports)
    body = without_constants(body)
    # variables of user / package types: "<type> name[, name ...];" (state_t st; py_core_pkg::trap_e cause;)
    for d in re.finditer(r"(?m)(?:^|;|\bbegin\b)\s*([A-Za-z_]\w*(?:::\w+)?)\s+((?:[A-Za-z_]\w*\s*(?:\[[^\]]*\]\s*)*,\s*)*[A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*(?:=[^;]*)?;", body):
        if d.group(1) in KEYWORDS or d.group(1) in ("assign", "return", "else", "end", "default"):
            continue
        for name in re.findall(r"([A-Za-z_]\w*)", re.sub(r"\[[^\]]*\]", " ", d.group(2))):
            if name not in KEYWORDS:
                sigs.add(name)
    for d in re.finditer(r"\b(?:logic|wire|reg|bit|tri1?|wand|wor)\b([^;]*);", body):
        decl = re.sub(r"\[[^\]]*\]", " ", d.group(1))
        decl = re.sub(r"=[^,;]*", " ", decl)
        for name in re.findall(r"([A-Za-z_]\w*)\s*(?:,|$)", decl.strip() + ","):
            if name not in KEYWORDS:
                sigs.add(name)
    return sigs


def logic_text(rest: str) -> str:
    """The module's own logic: drop declarations, functions and parameters (they are not data flow)."""
    rest = re.sub(r"\bfunction\b.*?\bendfunction\b", blank, rest, flags=re.S)
    # a net declaration with an initialiser (wire p = a ^ b;) is an assignment: keep it as one
    def net_assigns(m: re.Match) -> str:
        parts, depth, cur = [], 0, ""
        for ch in m.group(2):                                # split "a = x, b = y" at top-level commas
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur)
                cur = ""
            else:
                cur += ch
        parts.append(cur)
        stmts = [f"assign {p.strip()};" for p in parts if "=" in p]
        text = m.group(1) + " ".join(stmts)
        return text + "\n" * m.group(0).count("\n")
    rest = re.sub(r"(?m)(?:^|(?<=;))([ \t]*)(?:wire|logic|tri)\b(?:\s+[A-Za-z_]\w*(?:::\w+)?(?=\s+[A-Za-z_\[]))?"
                  r"(?:\s+signed)?\s*(?:\[[^\]]*\]\s*)*([A-Za-z_]\w*\s*(?:\[[^\]]*\]\s*)*=(?!=)[^;]*);",
                  net_assigns, rest)
    decl = r"(?m)(^|;)\s*(?:logic|wire|reg|bit|int|integer|genvar|localparam|parameter|typedef)\b[^;]*;"
    while re.search(decl, rest):                            # several declarations may share a line
        rest = re.sub(decl, lambda m: m.group(1) + blank(re.match(r".*", m.group(0)[len(m.group(1)):], re.S)), rest)
    return rest


def assigned_in(text: str, signals: set[str]) -> set[str]:
    out = set()
    for m in re.finditer(r"\bassign\s+(?:\{([^}]*)\}|([A-Za-z_]\w*))", text):
        out |= set(identifiers(m.group(1) or m.group(2), signals))
    for m in re.finditer(r"(?<![<>=!])\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*(<=|=)(?!=)", text):
        if m.group(1) in signals:
            out.add(m.group(1))
    for m in re.finditer(r"\{([^{}]*)\}\s*(<=|=)(?!=)", text):
        out |= set(identifiers(m.group(1), signals))
    return out


def registered(text: str, signals: set[str]) -> list[str]:
    regs = []
    for blk in re.finditer(r"always_ff\b.*?(?=always_ff\b|always_comb\b|\bassign\b|$)", text, re.S):
        for m in re.finditer(r"\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*<=", blk.group(0)):
            if m.group(1) in signals and m.group(1) not in regs:
                regs.append(m.group(1))
    return regs


# ======================================================================= graph

def q(s: str) -> str:
    return '"' + s.replace('"', '\\"') + '"'


def label_list(names: list[str], limit: int = 6) -> str:
    groups: list[str] = []
    for n in names:
        b = bundle(n)
        if b not in groups:
            groups.append(b)
    shown = groups[:limit]
    more = f"\\n+{len(groups) - limit} more" if len(groups) > limit else ""
    return "\\n".join(shown) + more


@dataclass
class BusEnd:
    node: str                      # graph node of this end
    prefix: str
    family: str                    # AXI4-Stream / AXI (AXI4 and AXI4-Lite)
    proto: str
    nets: set[str]
    source: bool                   # True: drives valid (master side, or a top-level slave port seen from inside)


def bus_ends(insts: list[Instance], idx: dict[str, ModInfo], decl, hidden: set[str]) -> list[BusEnd]:
    ends: list[BusEnd] = []
    for inst in insts:
        groups: dict[str, list[tuple[str, list[str]]]] = {}
        for port, sigs in inst.conns:
            b = bus_info(port)
            if b:
                groups.setdefault(b[0], []).append((port, [x for x in sigs if x not in hidden]))
        for prefix, members in groups.items():
            proto = bus_info(members[0][0])[1]
            dirs = idx[inst.module].ports
            valid = [p for p, _ in members if bus_info(p)[2] in ("valid", "awvalid", "arvalid")]
            source = bool(valid) and dirs.get(valid[0]) == "output"
            nets = {x for _, sigs in members for x in sigs}
            ends.append(BusEnd("inst:" + inst.name, prefix, "AXI4-Stream" if proto == "AXI4-Stream" else "AXI",
                               proto, nets, source))
    groups = {}
    for p in decl.ports:
        b = bus_info(p.name)
        if b and p.name not in hidden:
            groups.setdefault(b[0], []).append(p)
    for prefix, members in groups.items():
        proto = bus_info(members[0].name)[1]
        valid = [p for p in members if bus_info(p.name)[2] in ("valid", "awvalid", "arvalid")]
        source = bool(valid) and valid[0].direction == "input"      # a top slave port feeds the inside
        node = ("in:" if source else "out:") + prefix + "_*"
        ends.append(BusEnd(node, prefix, "AXI4-Stream" if proto == "AXI4-Stream" else "AXI", proto,
                           {p.name for p in members}, source))
    return ends


def pair_buses(ends: list[BusEnd]) -> tuple[list[tuple[str, str, str, list[str]]], set[tuple[str, str]]]:
    """Master / slave ends that share nets: one bus line each. Returns (lines, covered (net, node) pairs)."""
    lines, covered = [], set()
    for a in ends:
        if not a.source:
            continue
        for b in ends:
            if b.source or b.node == a.node or b.family != a.family:
                continue
            shared = sorted(a.nets & b.nets)
            if len(shared) < 2:
                continue
            proto = a.proto if a.proto == b.proto or b.node.startswith(("in:", "out:")) else b.proto
            lines.append((a.node, b.node, proto, shared))
            for n in shared:
                for end in (a, b):
                    covered.add((n, end.node))
                    if end.node.startswith(("in:", "out:")):     # a top-level port bus has an input and an output side
                        covered.add((n, "in:" + end.prefix + "_*"))
                        covered.add((n, "out:" + end.prefix + "_*"))
    return lines, covered


def bus_label(proto: str, nets: list[str]) -> str:
    cp = os.path.commonprefix(nets)
    name = (cp + "*") if len(cp) >= 2 else ", ".join(nets[:3]) + (" ..." if len(nets) > 3 else "")
    return f"{proto}\n{name} ({len(nets)})"


BUS_STYLE = 'penwidth=3.2, color="#0f766e", fontcolor="#0f766e", fontname="Courier", fontsize=9'


def build_graph(name: str, top: str, src: Path, idx: dict[str, ModInfo], title: str,
                build_files: list[Path]) -> str:
    text = preprocess(src.read_text(errors="replace"), design_defines(build_files))
    decl = parse_module(src, top, text)
    ports = {p.name: p for p in decl.ports}
    body = module_body(src, top, text)
    signals = declared_signals(body, list(ports))
    insts, rest = find_instances(body, idx, signals)
    rest = logic_text(rest)

    drivers: dict[str, set[str]] = {}
    loads: dict[str, set[str]] = {}
    nodes: dict[str, str] = {}

    def node_in(sig: str) -> str:
        return "in:" + bundle(sig)

    def node_out(sig: str) -> str:
        return "out:" + bundle(sig)

    for p in decl.ports:
        if p.direction in ("input", "inout"):
            drivers.setdefault(p.name, set()).add(node_in(p.name))
        if p.direction in ("output", "inout"):
            loads.setdefault(p.name, set()).add(node_out(p.name))

    for inst in insts:
        nid = "inst:" + inst.name
        nodes[nid] = inst.module
        dirs = idx[inst.module].ports
        for port, sigs in inst.conns:
            d = dirs.get(port, "inout")
            for s in sigs:
                if d in ("output", "inout"):
                    drivers.setdefault(s, set()).add(nid)
                if d in ("input", "inout"):
                    loads.setdefault(s, set()).add(nid)

    logic = "logic"
    assigned = assigned_in(rest, signals)
    for s in assigned:
        if not (s in ports and ports[s].direction == "input"):
            drivers.setdefault(s, set()).add(logic)
    used = set(identifiers(rest, signals))
    for s in used - assigned:
        loads.setdefault(s, set()).add(logic)
    for s in used & assigned:                                  # read and written: a register / feedback in the logic
        if any(d != logic for d in drivers.get(s, ())):
            loads.setdefault(s, set()).add(logic)
    regs = registered(rest, signals)

    edges: dict[tuple[str, str], list[str]] = {}
    clk_rst = sorted(p.name for p in decl.ports if p.direction == "input" and is_clock_or_reset(p.name, ports))
    data_in = [p for p in decl.ports if p.direction != "output" and p.name not in clk_rst]
    data_out = [p for p in decl.ports if p.direction != "input" and p.name not in clk_rst]
    if not data_in or not data_out:      # clock / reset blocks (reset_sync ...): their clocks and resets are the data
        clk_rst = []
    hidden_sys = set(clk_rst) | {x for x in signals if x not in ports and is_clock_or_reset(x, ports) and clk_rst}
    bus_lines, covered = pair_buses(bus_ends(insts, idx, decl, hidden_sys))
    for s in sorted(signals, key=lambda x: (x not in ports, x)):
        if s in clk_rst or (s not in ports and is_clock_or_reset(s, ports) and clk_rst):
            continue                                         # internal clock / reset nets are not drawn either
        for d in drivers.get(s, ()):
            for l in loads.get(s, ()):
                if d != l and not ((s, d) in covered and (s, l) in covered):   # bus member: drawn by the bus line
                    edges.setdefault((d, l), []).append(s)

    used_nodes = {n for e in edges for n in e} | {n for a, b, _, _ in bus_lines for n in (a, b)}
    has_logic = logic in used_nodes or (not insts)
    idle = [f"{nodes[n]} {n.split(':', 1)[1]}" for n in nodes if n not in used_nodes]
    for n in [n for n in nodes if n not in used_nodes]:
        del nodes[n]

    out = [f"digraph {q(name + '_dataflow')} {{",
           '  graph [rankdir=LR, bgcolor="white", pad=0.3, nodesep=0.3, ranksep=1.1, fontname="Helvetica", '
           f'labelloc=t, labeljust=l, label=<<FONT POINT-SIZE="18"><B>{html.escape(top)}</B> data flow</FONT>'
           f'<BR ALIGN="LEFT"/><FONT POINT-SIZE="11" COLOR="#4b5563">{html.escape(title)}'
           + (f'; clocks / resets (not drawn): {html.escape(", ".join(clk_rst))}' if clk_rst else "")
           + (f'<BR ALIGN="LEFT"/>clock / reset only (not drawn): {html.escape(", ".join(idle))}' if idle else "")
           + '<BR ALIGN="LEFT"/>thick teal line = protocol bus (AXI4-Stream / AXI4 / AXI4-Lite, ready and responses implied); '
             'a bus signal also used elsewhere is drawn separately</FONT><BR ALIGN="LEFT"/>' + ">];",
           '  node [fontname="Helvetica", fontsize=10];',
           '  edge [fontname="Courier", fontsize=9, color="#374151", fontcolor="#1f2937", arrowsize=0.7];']

    def port_label(key: str, prefix: str) -> str:
        b = key.split(":", 1)[1]
        members = [p for p in decl.ports if bundle(p.name) == b]
        width = members[0].width if len(members) == 1 and members[0].width != "1" else ""
        sub = f"\\n{len(members)} signals" if len(members) > 1 else (f"\\n{width}" if width else "")
        return f"{b}{sub}"

    bus_covered_ports = {n for n, _ in covered if n in ports}
    ins = sorted({n for n in used_nodes if n.startswith("in:")} |
                 {node_in(p.name) for p in decl.ports if p.direction in ("input", "inout") and p.name not in clk_rst
                  and p.name not in bus_covered_ports})
    outs = sorted({n for n in used_nodes if n.startswith("out:")} |
                  {node_out(p.name) for p in decl.ports if p.direction in ("output", "inout") and p.name not in bus_covered_ports})
    out.append('  subgraph cluster_in { label="inputs"; style="rounded,dashed"; color="#9ca3af"; fontcolor="#4b5563"; fontsize=10;')
    for n in ins:
        out.append(f'    {q(n)} [shape=box, style="rounded,filled", fillcolor="#dcfce7", color="#15803d", label={q(port_label(n, "in"))}];')
    out.append("  }")
    out.append('  subgraph cluster_out { label="outputs"; style="rounded,dashed"; color="#9ca3af"; fontcolor="#4b5563"; fontsize=10;')
    for n in outs:
        out.append(f'    {q(n)} [shape=box, style="rounded,filled", fillcolor="#dbeafe", color="#1d4ed8", label={q(port_label(n, "out"))}];')
    out.append("  }")
    for nid, mod in nodes.items():
        out.append(f'  {q(nid)} [shape=box, style="filled", fillcolor="#fef9c3", color="#a16207", '
                   f'label=<<B>{html.escape(mod)}</B><BR/><FONT COLOR="#4b5563">{html.escape(nid.split(":", 1)[1])}</FONT>>];')
    if has_logic:
        reg_txt = ""
        if regs:
            shown = regs[:10]
            reg_txt = "<BR/><FONT POINT-SIZE=\"9\" COLOR=\"#4b5563\">registers: " + html.escape(", ".join(shown)) + \
                      (f" +{len(regs) - 10}" if len(regs) > 10 else "") + "</FONT>"
        what = f"{top} logic" if insts else f"{top}"
        out.append(f'  {q(logic)} [shape=box, style="rounded,filled", fillcolor="#ede9fe", color="#7c3aed", '
                   f'label=<<B>{html.escape(what)}</B>{reg_txt}>];')
    for (d, l), sigs in sorted(edges.items()):
        if not has_logic and logic in (d, l):
            continue
        out.append(f"  {q(d)} -> {q(l)} [label={q(label_list(sigs))}];")
    for a, b, proto, nets in bus_lines:
        out.append(f"  {q(a)} -> {q(b)} [{BUS_STYLE}, label={q(bus_label(proto, nets))}];")
    if not edges and not insts:                              # leaf module whose body references nothing parseable
        for n in ins:
            out.append(f"  {q(n)} -> {q(logic)};")
        for n in outs:
            out.append(f"  {q(logic)} -> {q(n)};")
    out.append("}")
    return "\n".join(out) + "\n"


# ======================================================================= RTL-level graph (IP blocks)

TOKEN_RE = re.compile(r"""
    (?P<nl>\n)
  | (?P<ws>[ \t\r\f]+)
  | (?P<id>[A-Za-z_$][\w$]*(?:::[A-Za-z_]\w*)?)
  | (?P<num>\d*'[sS]?[bodhBODH][0-9a-fA-F_xXzZ?]+|'[01xXzZ]|\d[\d_]*(?:\.\d+)?)
  | (?P<op><<<=|>>>=|===|!==|<<=|>>=|<=|>=|==|!=|&&|\|\||<<<|>>>|<<|>>|\+:|-:|\+=|-=|\|=|&=|\^=|\*=|\+\+|--|\*\*|.)
""", re.X)

ASSIGN_OPS = {"=", "<=", "+=", "-=", "|=", "&=", "^=", "*=", "<<=", ">>=", "<<<=", ">>>="}
OPENERS, CLOSERS = {"(": ")", "[": "]", "{": "}"}, {")", "]", "}"}


def tokenize(text: str, first_line: int) -> list[tuple[str, int]]:
    toks, line = [], first_line
    for m in TOKEN_RE.finditer(text):
        k = m.lastgroup
        if k == "nl":
            line += 1
        elif k != "ws":
            toks.append((m.group(), line))
    return toks


@dataclass
class Assignment:
    targets: list[str]
    deps: list[str]
    kind: str                      # "ff", "comb", "assign", "latch"
    block: str                     # block id ("always_ff @ line N", or "" for assign)


class RtlParser:
    """Statement-level parser of a module body: which signals each assignment reads (data and the
    if / case conditions around it). Constructs it does not know are skipped to the next ';'."""

    def __init__(self, toks: list[tuple[str, int]], signals: set[str]):
        self.t = [x for x, _ in toks]
        self.line = [l for _, l in toks]
        self.n = len(self.t)
        self.signals = signals
        self.out: list[Assignment] = []
        self.edge_signals: set[str] = set()          # used as posedge / negedge: clocks and asynchronous resets

    def ids(self, a: int, b: int) -> list[str]:
        out = []
        for k in range(a, b):
            w = self.t[k]
            if w in self.signals and w not in out and not (k > 0 and self.t[k - 1] in (".", "'")):
                out.append(w)
        return out

    def skip_group(self, i: int) -> int:
        """i at an opener: index after its matching closer."""
        depth = 0
        while i < self.n:
            w = self.t[i]
            if w in OPENERS:
                depth += 1
            elif w in CLOSERS:
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        return i

    def to_semicolon(self, i: int) -> int:
        depth = 0
        while i < self.n:
            w = self.t[i]
            if w in OPENERS:
                depth += 1
            elif w in CLOSERS:
                depth -= 1
            elif w == ";" and depth <= 0:
                return i + 1
            i += 1
        return i

    def stmt(self, i: int, conds: list[str], kind: str, block: str) -> int:
        if i >= self.n:
            return i
        w = self.t[i]
        if w in ("unique", "unique0", "priority"):
            return self.stmt(i + 1, conds, kind, block)
        if w == "begin":
            i += 1
            if i < self.n and self.t[i] == ":":
                i += 2
            while i < self.n and self.t[i] != "end":
                j = self.stmt(i, conds, kind, block)
                i = j if j > i else i + 1
            i += 1
            if i < self.n and self.t[i] == ":":
                i += 2
            return i
        if w == "if" and i + 1 < self.n and self.t[i + 1] == "(":
            e = self.skip_group(i + 1)
            c = conds + self.ids(i + 1, e)
            i = self.stmt(e, c, kind, block)
            if i < self.n and self.t[i] == "else":
                i = self.stmt(i + 1, c, kind, block)
            return i
        if w in ("case", "casez", "casex") and i + 1 < self.n and self.t[i + 1] == "(":
            e = self.skip_group(i + 1)
            c = conds + self.ids(i + 1, e)
            i = e
            if i < self.n and self.t[i] == "inside":
                i += 1
            while i < self.n and self.t[i] != "endcase":
                if self.t[i] == "default":
                    i += 1
                    if i < self.n and self.t[i] == ":":
                        i += 1
                    labels = []
                else:
                    a, depth = i, 0
                    while i < self.n and not (self.t[i] == ":" and depth == 0) and self.t[i] != "endcase":
                        if self.t[i] in OPENERS:
                            depth += 1
                        elif self.t[i] in CLOSERS:
                            depth -= 1
                        i += 1
                    labels = self.ids(a, i)
                    i += 1
                j = self.stmt(i, c + labels, kind, block)
                i = j if j > i else i + 1
            return i + 1
        if w in ("for", "foreach", "while", "repeat") and i + 1 < self.n and self.t[i + 1] == "(":
            return self.stmt(self.skip_group(i + 1), conds, kind, block)
        if w in ("forever", "do"):
            return self.stmt(i + 1, conds, kind, block)
        if w == ";":
            return i + 1
        if w.startswith("$readmem") and i + 1 < self.n and self.t[i + 1] == "(":
            e = self.skip_group(i + 1)                       # $readmemh(file, mem): mem is loaded from a file
            targets = self.ids(i + 1, e)
            if targets:
                self.out.append(Assignment(targets, [], kind, block))
            return self.to_semicolon(e)
        # assignment (or a call / local declaration, which has no assignment target that is a signal)
        end = self.to_semicolon(i)
        depth, op = 0, None
        for k in range(i, end):
            x = self.t[k]
            if x in OPENERS:
                depth += 1
            elif x in CLOSERS:
                depth -= 1
            elif depth == 0 and x in ASSIGN_OPS:
                op = k
                break
            elif depth == 0 and x in ("++", "--"):
                op = k
                break
        if op is not None:
            # lhs: base names (outside index brackets) are targets, names inside [] are dependencies
            targets, idx_deps, depth = [], [], 0
            for k in range(i, op):
                x = self.t[k]
                if x in ("[", "("):
                    depth += 1
                elif x in ("]", ")"):
                    depth -= 1
                elif x in self.signals:
                    (idx_deps if depth > 0 else targets).append(x)
            deps = self.ids(op + 1, end) + idx_deps + conds
            if self.t[op] not in ("=", "<="):          # x += y, x++: x also feeds itself
                deps += targets
            if targets:
                self.out.append(Assignment(targets, list(dict.fromkeys(deps)), kind, block))
        return end

    def run(self) -> list[Assignment]:
        i = 0
        while i < self.n:
            w = self.t[i]
            if w in ("always_ff", "always_comb", "always_latch", "always"):
                line = self.line[i]
                kind = {"always_ff": "ff", "always_comb": "comb", "always_latch": "latch"}.get(w, "always")
                i += 1
                sens = []
                if i < self.n and self.t[i] == "@":
                    i += 1
                    if i < self.n and self.t[i] == "(":
                        e = self.skip_group(i)
                        sens = self.t[i:e]
                        i = e
                    elif i < self.n and self.t[i] == "*":
                        i += 1
                if kind == "always":
                    kind = "ff" if any(x in ("posedge", "negedge") for x in sens) else "comb"
                # edge-sensitive signals (clock, asynchronous reset) feed every register of the block
                edge_sigs = [sens[k + 1] for k in range(len(sens) - 1)
                             if sens[k] in ("posedge", "negedge") and sens[k + 1] in self.signals]
                self.edge_signals |= set(edge_sigs)
                i = self.stmt(i, edge_sigs, kind, f"{w} @ line {line}")
                continue
            if w == "initial":
                line = self.line[i]
                i = self.stmt(i + 1, [], "init", f"initial @ line {line}")
                continue
            if w == "task":
                line = self.line[i]
                i = self.to_semicolon(i + 1)                   # task header
                name = self.t[i - 2] if i >= 2 else "task"
                while i < self.n and self.t[i] != "endtask":
                    j = self.stmt(i, [], "ff", f"task @ line {line}")
                    i = j if j > i else i + 1
                i += 1
                continue
            if w == "assign":
                end = self.to_semicolon(i + 1)
                depth, op = 0, None
                for k in range(i + 1, end):
                    x = self.t[k]
                    if x in OPENERS:
                        depth += 1
                    elif x in CLOSERS:
                        depth -= 1
                    elif depth == 0 and x == "=":
                        op = k
                        break
                if op is not None:
                    targets, idx_deps, depth = [], [], 0
                    for k in range(i + 1, op):
                        x = self.t[k]
                        if x in ("[", "("):
                            depth += 1
                        elif x in ("]", ")"):
                            depth -= 1
                        elif x in self.signals:
                            (idx_deps if depth > 0 else targets).append(x)
                    if targets:
                        self.out.append(Assignment(targets, list(dict.fromkeys(self.ids(op + 1, end) + idx_deps)),
                                                   "assign", ""))
                i = end
                continue
            i += 1
        return self.out


def declared_widths(body: str) -> dict[str, str]:
    widths: dict[str, str] = {}
    body = without_constants(body)
    for d in re.finditer(r"\b(?:logic|wire|reg|bit|tri1?)\b\s*(signed\s+)?((?:\[[^\]]*\]\s*)*)([^;]*);", body):
        packed = re.sub(r"\s+", "", d.group(2))
        for m in re.finditer(r"([A-Za-z_]\w*)\s*((?:\[[^\]]*\]\s*)*)(?:=[^,;]*)?(?:,|$)", d.group(3).strip()):
            unpacked = re.sub(r"\s+", "", m.group(2))
            if m.group(1) not in KEYWORDS:
                widths[m.group(1)] = (packed or "") + (" x " + unpacked if unpacked else "")
    return widths


def ip_graph(name: str, top: str, src: Path, idx: dict[str, ModInfo], title: str, build_files: list[Path]) -> str:
    text = preprocess(src.read_text(errors="replace"), design_defines(build_files))
    decl = parse_module(src, top, text)
    ports = {p.name: p for p in decl.ports}
    body = module_body(src, top, text)
    first = body_first_line(src, top, text)
    signals = declared_signals(body, list(ports))
    widths = declared_widths(body)
    insts, rest = find_instances(body, idx, signals)
    rest = logic_text(rest)
    parser = RtlParser(tokenize(rest, first), signals)
    assigns = parser.run()

    clk_rst = sorted(p.name for p in decl.ports if p.direction == "input" and is_clock_or_reset(p.name, ports))
    data_in = [p for p in decl.ports if p.direction != "output" and p.name not in clk_rst]
    data_out = [p for p in decl.ports if p.direction != "input" and p.name not in clk_rst]
    if not data_in or not data_out:
        clk_rst = []
    if re.search(r"rst|reset", top, re.I):                  # reset controllers: their resets are the data
        clk_rst = [c for c in clk_rst if CLOCK_RE.search(c)]
    internal_hidden = {s for s in signals if s not in ports and
                       (CLOCK_RE.search(s) or re.search(r"(rst|reset)_?n$|rstn$|resetn$", s, re.I))}
    # internal nets used as clocks / asynchronous resets (wire rc = ASYNC ? rclk : wclk; always_ff @(posedge rc))
    internal_hidden |= {x for x in parser.edge_signals if x not in ports}
    hidden = set(clk_rst) | (internal_hidden if clk_rst else set())

    def node(sig: str, as_target: bool = False) -> str:
        p = ports.get(sig)
        if p is not None:
            if p.direction == "input":
                return "in:" + bundle(sig)
            if p.direction == "output":
                return "out:" + bundle(sig)
            return ("out:" if as_target else "in:") + bundle(sig)
        return "sig:" + sig

    edges: set[tuple[str, str]] = set()
    const_out: set[str] = set()                   # outputs assigned a constant
    kinds: dict[str, str] = {}                    # internal signal -> ff / comb / assign / latch
    block_of: dict[str, str] = {}
    for a in assigns:
        for t in a.targets:
            if t in hidden:
                continue
            if t not in ports:
                kinds.setdefault(t, a.kind)
                if a.block:
                    block_of.setdefault(t, a.block)
            if not a.deps:
                const_out.add(t)
            for d in a.deps:
                if d in hidden:
                    continue
                edges.add((node(d), node(t, True)))           # d == t: feedback (counter, toggle, FSM)
    # protocol buses between instances / ports: one line; a member also used elsewhere is broken out
    bus_lines, covered = pair_buses(bus_ends(insts, idx, decl, hidden))
    logic_nets = {x for a in assigns for x in a.targets + a.deps if x not in hidden}
    links: list[tuple[str, str, str]] = []           # (instance node, net, drive / load)
    for inst in insts:
        nid = "inst:" + inst.name
        dirs = idx[inst.module].ports
        for port, sigs in inst.conns:
            d = dirs.get(port, "inout")
            for sg in sigs:
                if sg in hidden:
                    continue
                if d in ("output", "inout"):
                    links.append((nid, sg, "drive"))
                if d in ("input", "inout"):
                    links.append((nid, sg, "load"))

    def top_node_of(sg: str) -> str | None:
        p = ports.get(sg)
        return None if p is None else ("in:" if p.direction == "input" else "out:") + bundle(sg)

    def used_elsewhere(sg: str) -> bool:
        if sg in logic_nets:
            return True
        if any(n == sg and (sg, nid) not in covered for nid, n, _ in links):
            return True
        t = top_node_of(sg)
        return t is not None and (sg, t) not in covered and any(n == sg for _, n, _ in links)

    inst_nodes = {}
    for nid, sg, role in links:
        if (sg, nid) in covered and not (role == "drive" and used_elsewhere(sg)):
            inst_nodes.setdefault(nid, None)
            continue                                       # carried by the bus line
        if sg not in ports:
            kinds.setdefault(sg, "inst")
        edges.add((nid, node(sg, True)) if role == "drive" else (node(sg), nid))
        inst_nodes.setdefault(nid, None)
    mods = {"inst:" + i.name: i.module for i in insts}
    inst_nodes = {n: mods[n] for n in inst_nodes if any(n in e for e in edges) or any(n in (a, b) for a, b, _, _ in bus_lines)}
    idle = [f"{i.module} {i.name}" for i in insts if "inst:" + i.name not in inst_nodes]
    for t in const_out:                            # outputs / nets assigned only constants get a constant source
        tn = node(t, True)
        if not any(b == tn for _, b in edges) and (t in ports or any(tn in e for e in edges)):
            edges.add(("const:" + t, tn))
    edges = {(a, b) for a, b in edges if a != b or a.startswith("sig:") or a.startswith("out:")}
    used = {n for e in edges for n in e} | {n for a, b, _, _ in bus_lines for n in (a, b)}

    L = [f"digraph {q(name + '_dataflow')} {{",
         '  graph [rankdir=LR, bgcolor="white", pad=0.3, nodesep=0.18, ranksep=0.9, fontname="Helvetica", newrank=true, '
         f'labelloc=t, labeljust=l, label=<<FONT POINT-SIZE="18"><B>{html.escape(top)}</B> data flow (RTL level)</FONT>'
         f'<BR ALIGN="LEFT"/><FONT POINT-SIZE="11" COLOR="#4b5563">{html.escape(title)}'
         + (f'; clocks / resets (not drawn): {html.escape(", ".join(clk_rst))}' if clk_rst else "")
         + (f'<BR ALIGN="LEFT"/>clock / reset only (not drawn): {html.escape(", ".join(idle))}' if idle else "")
         + '<BR ALIGN="LEFT"/>box with double border = register (always_ff), ellipse = combinational (assign / always_comb), '
           'yellow = sub-module instance; clusters = the always block that drives them<BR ALIGN="LEFT"/>'
           'thick teal line = protocol bus (AXI4-Stream / AXI4 / AXI4-Lite, ready and responses implied); '
           'a bus signal also used elsewhere is drawn separately</FONT><BR ALIGN="LEFT"/>' + ">];",
         '  node [fontname="Helvetica", fontsize=9];',
         '  edge [color="#4b5563", arrowsize=0.6, penwidth=0.9];']

    def port_label(key: str) -> str:
        side, b = key.split(":", 1)
        want = ("input", "inout") if side == "in" else ("output", "inout")
        members = [p for p in decl.ports if bundle(p.name) == b and p.name not in hidden and p.direction in want]
        if len(members) > 1:
            return f"{b}\\n" + "\\n".join(p.name for p in members)
        w = members[0].width if members and members[0].width != "1" else ""
        shown = members[0].name if members else b               # one member: name the signal itself
        return f"{shown}" + (f"\\n{w}" if w else "")

    bus_covered_ports = {n for n, _ in covered if n in ports}         # drawn by a bus line from the other side
    ins = sorted({n for n in used if n.startswith("in:")} |
                 {"in:" + bundle(p.name) for p in decl.ports if p.direction != "output" and p.name not in hidden
                  and p.name not in bus_covered_ports})
    outs = sorted({n for n in used if n.startswith("out:")} |
                  {"out:" + bundle(p.name) for p in decl.ports if p.direction != "input" and p.name not in hidden
                   and p.name not in bus_covered_ports})
    # inputs pinned to the left edge, outputs to the right edge
    L.append('  subgraph cluster_in { label="inputs"; style="rounded,dashed"; color="#9ca3af"; fontcolor="#4b5563"; fontsize=10;')
    L.append("    { rank=min; " + " ".join(q(n) for n in ins) + " }")
    L += [f'    {q(n)} [shape=box, style="rounded,filled", fillcolor="#dcfce7", color="#15803d", label={q(port_label(n))}];' for n in ins]
    L.append("  }")
    L.append('  subgraph cluster_out { label="outputs"; style="rounded,dashed"; color="#9ca3af"; fontcolor="#4b5563"; fontsize=10;')
    L.append("    { rank=max; " + " ".join(q(n) for n in outs) + " }")
    L += [f'    {q(n)} [shape=box, style="rounded,filled", fillcolor="#dbeafe", color="#1d4ed8", label={q(port_label(n))}];' for n in outs]
    L.append("  }")

    def sig_node(sg: str) -> str:
        k = kinds.get(sg, "comb")
        w = widths.get(sg, "")
        lbl = sg + (f"\\n{w}" if w else "")
        if k == "ff":
            return f'{q("sig:" + sg)} [shape=box, peripheries=2, style="filled", fillcolor="#ede9fe", color="#7c3aed", label={q(lbl)}];'
        if k == "inst":
            return f'{q("sig:" + sg)} [shape=ellipse, style="filled", fillcolor="#fff7ed", color="#c2410c", label={q(lbl)}];'
        return f'{q("sig:" + sg)} [shape=ellipse, style="filled", fillcolor="#f3f4f6", color="#6b7280", label={q(lbl)}];'

    internal = sorted({n.split(":", 1)[1] for n in used if n.startswith("sig:")})
    clusters: dict[str, list[str]] = {}
    for sg in internal:
        clusters.setdefault(block_of.get(sg, ""), []).append(sg)
    for k, (blk, sigs) in enumerate(sorted(clusters.items(), key=lambda x: (x[0] == "", x[0]))):
        if blk:
            L.append(f'  subgraph cluster_b{k} {{ label={q(blk)}; style="rounded"; color="#c4b5fd"; fontcolor="#6d28d9"; fontsize=9;')
            L += ["    " + sig_node(sg) for sg in sigs]
            L.append("  }")
        else:
            L += ["  " + sig_node(sg) for sg in sigs]
    for c in sorted(n for n in used if n.startswith("const:")):
        L.append(f'  {q(c)} [shape=plaintext, fontcolor="#6b7280", fontsize=8, label="constant"];')
    for nid, mod in inst_nodes.items():
        L.append(f'  {q(nid)} [shape=box, style="filled", fillcolor="#fef9c3", color="#a16207", '
                 f'label=<<B>{html.escape(mod)}</B><BR/><FONT COLOR="#4b5563">{html.escape(nid.split(":", 1)[1])}</FONT>>];')
    for a, b in sorted(edges):
        L.append(f"  {q(a)} -> {q(b)};")
    for a, b, proto, nets in bus_lines:
        L.append(f"  {q(a)} -> {q(b)} [{BUS_STYLE}, label={q(bus_label(proto, nets))}];")
    L.append("}")
    return "\n".join(L) + "\n"


# ======================================================================= main

def targets(mods) -> list[tuple[str, str, Path, Path, bool]]:
    """(name, top module, top source, docs dir) for every IP, system, design-local IP and example."""
    tops = {}
    for row in csv.reader(l for l in (IP_ROOT / "scripts" / "ips.csv").read_text().splitlines() if l and not l.startswith("#")):
        if len(row) >= 3:
            tops[row[0].strip()] = row[2].strip()
    out = []
    for m in sorted(mods.values(), key=lambda m: (m.category, m.name)):
        top = m.name if m.system else tops.get(m.name, m.name)
        src = m.path / "src" / f"{top}.sv"
        if not src.is_file():
            src = next((f for f in build_list(m.path / "scripts" / "build.f") if f.stem == top), Path("-"))
        if src.is_file():
            out.append((m.name, top, src, m.path / "docs", m.system))
    for sysdir in sorted(p for p in SYSTEMS_ROOT.iterdir() if (p / "ip").is_dir()):
        for sub in sorted(p for p in (sysdir / "ip").iterdir() if (p / "src").is_dir()):
            srcs = sorted((sub / "src").glob("*.sv"))
            src = sub / "src" / f"{sub.name}.sv"
            if not src.is_file() and srcs:
                src = next((f for f in srcs if f.stem.startswith(sub.name)), srcs[0])
            if src.is_file():
                out.append((sub.name, src.stem, src, sub / "docs", False))
    for ex in sorted(p for p in (IP_ROOT / "examples").iterdir() if p.is_dir()):
        for src in sorted(ex.glob("*.sv")):
            out.append((src.stem, src.stem, src, ex / "docs", False))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Write <dir>/docs/<name>_dataflow.dot/.svg for every block.")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--no-svg", action="store_true")
    args = ap.parse_args()
    dot = shutil.which("dot")
    if not dot and not args.no_svg:
        print("Graphviz 'dot' not found: writing .dot files only")
    mods = discover()
    idx = index_modules()
    n = 0
    for name, top, src, docs, system in targets(mods):
        if args.only and name not in args.only:
            continue
        title = f"signal names from {src.relative_to(REPO)}"
        bf = docs.parent / "scripts" / "build.f"
        if not bf.is_file():
            bf = docs.parent / "src" / "build.f"
        files = build_list(bf)
        # systems: block-level view; IP blocks: RTL-level view (every register, net and dependency)
        text = (build_graph if system else ip_graph)(name, top, src, idx, title, files)
        docs.mkdir(exist_ok=True)
        dot_file = docs / f"{name}_dataflow.dot"
        dot_file.write_text(text, encoding="utf-8")
        if dot and not args.no_svg:
            try:
                r = subprocess.run([dot, "-Tsvg", str(dot_file), "-o", str(dot_file.with_suffix(".svg"))],
                                   capture_output=True, text=True, timeout=600)
                if r.returncode:
                    print(f"dot failed for {name}: {r.stderr.strip()[:200]}")
            except subprocess.TimeoutExpired:
                print(f"dot timed out for {name}: .dot written, render it separately")
        print(dot_file.relative_to(REPO))
        n += 1
    print(f"{n} data-flow diagrams")


if __name__ == "__main__":
    main()
