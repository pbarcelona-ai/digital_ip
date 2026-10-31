#!/usr/bin/env python3
# ***************
# Filename: cdc_check.py
# Author: FPGA Cores 4 U
# Description: Structural clock-domain-crossing check of a design on its
#   flattened Yosys netlist (JSON, write_json after proc; flatten; memory
#   -nomap). Every sequential cell ($*dff*, $dlatch*, $mem_v2) gets the
#   clock root of its clock pin: the clock net traced back through
#   combinational cells (gating, muxes) to a black-box output (a PLL
#   oscillator), a top-level input or a register output (a divided clock).
#   For every data, enable and reset input of a sequential cell the
#   combinational cone is traced back to its source cells; a source with
#   another clock root is a crossing. A crossing is
#     allowed   when the destination cell carries the attribute cdc_sync
#               (set by the Yosys script on the cells of the library's CDC
#               modules before flattening: bit_sync, cdc_sync_bit,
#               pulse_sync, toggle_sync, reset_sync, async_fifo, ...) or
#               its register's name matches a --sync-inst pattern, or lies
#               under an instance of a library CDC module found in the
#               --sync-src sources (a netlist flattened while elaborating,
#               e.g. yosys-slang's, or CDC modules sv2v inlined: the
#               instance name stays a prefix of the register's);
#     held      when the source register lies in a CDC module instance (the
#               same tags / names): the block's own data or address register,
#               held stable across its handshake (axi4_lite_cdc's request,
#               async_fifo's memory) - the block's review and tests own it;
#     related   when both roots are outputs of the same black-box cell (one
#               PLL oscillator: phase-aligned clocks, e.g. a serializer's
#               pixel and bit clocks) - listed, not an error;
#     violation otherwise (exit status 1).
#   Allowed crossings are also checked for combinational logic between the
#   source registers and a single-bit synchronizer's first stage that mixes
#   several source bits of other domains (a glitch can be captured; a
#   synchronous reset or enable of the destination's own domain does not
#   count): listed as warnings.
#   Top-level inputs other than clocks are listed as external sources (the
#   board's; no check). Waivers: --waive <regex> on "src -> dst" lines, or
#   --waive-file (a regex and its reason per line, listed in the report).
#   Black-box outputs are a domain of their own unless --bb-clock names the
#   input clock they are registered on (MODULE:PIN=CLKPIN).
#   Output: a report on stdout (--out writes it to a file too).
#   Limits: structural only - a multi-bit value crossing under a handshake
#   (axi4_lite_cdc, async_fifo) is trusted to the library CDC block (its
#   own review and tests), reset sequencing is not checked, and black boxes
#   without port directions have them guessed from the pin names.
# Date: 2026-10-27
# ***************
"""Usage: cdc_check.py <netlist.json> [--top NAME] [--sync-inst REGEX ...] [--sync-src FILELIST] [--waive REGEX ...]
[--out FILE] [--max N]"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict

# the library's clock-domain-crossing modules (ip/cdc, ip/fifo/async_fifo): their instances are synchronisers
CDC_MODULES = ("bit_sync", "cdc_sync_bit", "pulse_sync", "reset_sync", "toggle_sync", "async_fifo", "axi4_lite_cdc",
               "axis_async_bridge", "clock_domain_bridge", "reset_ctrl",
               "mipi_line_buf")                  # its line memory: written, then read once the line's event has crossed
SEQ = re.compile(r"^\$(_?)(a?l?s?dff\w*|dffe\w*|sdff\w*|adff\w*|aldff\w*|dffsr\w*|dlatch\w*|_DFF\w*|_SDFF\w*|_DLATCH\w*)$")
MEM = ("$mem_v2", "$mem")
# the inputs of a sequential cell that are data (checked) and its clock pins
DATA_PINS = ("D", "EN", "SRST", "ARST", "AD", "ALOAD", "CLR", "SET", "E", "R", "S")
CLK_PINS = ("CLK", "C")


def is_seq(t: str) -> bool:
    return bool(SEQ.match(t)) or t in MEM


def load(path: str, top: str | None):
    with open(path, encoding="utf-8") as fh:
        nl = json.load(fh)
    mods = nl["modules"]
    if top is None:
        tops = [n for n, m in mods.items() if m.get("attributes", {}).get("top")]
        top = tops[0] if tops else next(iter(mods))
    return mods, top


class Netlist:
    def __init__(self, mods, top):
        m = mods[top]
        self.mods = mods
        self.cells = m["cells"]
        self.ports = m.get("ports", {})
        self.driver = {}                                 # bit -> (cell name or "port:<name>", pin)
        self.dbit = {}                                   # bit -> its index in that pin's bits
        self.netname = {}
        for n, p in self.ports.items():
            if p["direction"] == "input":
                for i, b in enumerate(p["bits"]):
                    if isinstance(b, int):
                        self.driver[b] = (f"port:{n}", i)
        for cn, c in self.cells.items():
            dirs = c.get("port_directions", {})
            for pin, bits in c["connections"].items():
                d = dirs.get(pin)
                if d is None:                            # a black box without directions: guess from the name
                    d = "output" if re.search(r"(_o|out|Q|Y)$", pin) else "input"
                if d == "output":
                    for i, b in enumerate(bits):
                        if isinstance(b, int):
                            self.driver[b] = (cn, pin)
                            self.dbit[b] = i
        self.names = defaultdict(set)                   # bit -> every net name on it
        self.nline = {}                                  # net name -> its declaration's line
        self.netbits = {}                                # net name -> its bits
        self.async_nets = set()                          # nets of registers marked async_reg (synchroniser stages)
        for nn, nd in m.get("netnames", {}).items():
            mm = re.match(r"[^:]*:(\d+)", str(nd.get("attributes", {}).get("src", "")))
            self.nline[nn] = int(mm.group(1)) if mm else 0
            self.netbits[nn] = nd["bits"]
            if str(nd.get("attributes", {}).get("async_reg", "")).lower() in ("true", "1", "yes") or \
                    re.fullmatch(r"0*1", str(nd.get("attributes", {}).get("async_reg", ""))):
                self.async_nets.add(nn)
            for b in nd["bits"]:
                if isinstance(b, int):
                    self.names[b].add(nn)
        for b, ns in self.names.items():                 # a net's name: an internal one (not a top port), the
            inner = [n for n in ns if n not in self.ports] or list(ns)   # shortest
            self.netname[b] = min(inner, key=lambda n: (n.startswith("$"), len(n), n))

    def clock_name(self, b):
        """A clock bit's name: a single-bit internal net on it (the shortest), else a bus with the bit's index."""
        ns = [n for n in self.names.get(b, ()) if n not in self.ports] or list(self.names.get(b, ()))
        if not ns:
            return str(b)
        one = [n for n in ns if len(self.netbits.get(n, ())) == 1]
        if one:
            return min(one, key=lambda n: (n.startswith("$"), len(n), n))
        n = min(ns, key=lambda n: (n.startswith("$"), len(n), n))
        return f"{n}[{self.netbits[n].index(b)}]"

    def onames(self, cn):
        """Every net name on a sequential cell's first output bit."""
        c = self.cells[cn]
        for pin in ("Q", "RD_DATA"):
            bits = c["connections"].get(pin, [])
            if bits and isinstance(bits[0], int):
                return self.names.get(bits[0], set())
        return set()

    def path(self, cn):
        """The instance a cell lies in ('' at the top): from a flattened cell's name ($flatten\\<path>.$...,
        yosys-slang's $driver$<path>.<signal>, or a public <path>.<name>)."""
        if cn.startswith("$driver$"):
            sig = cn[len("$driver$"):]
            return sig.rsplit(".", 1)[0] if "." in sig else ""
        if cn.startswith("$flatten"):
            rest = cn[len("$flatten"):].replace("\\", "")
            i = rest.rfind(".$")
            return rest[:i] if i >= 0 else ""
        if not cn.startswith("$") and "." in cn:
            return cn.rsplit(".", 1)[0]
        return ""

    def dname(self, cn):
        """A sequential cell's own name, the register's hierarchical name: yosys-slang's $driver$<signal>, or a
        name of its output net in the cell's own instance (not a port alias of it in a parent or child, not a
        top port; of several the latest declared: ports come first in a module), else the output net's name, else
        the cell's."""
        if cn.startswith("$driver$"):
            return cn[len("$driver$"):]
        c = self.cells[cn]
        p = self.path(cn)
        for pin in ("Q", "RD_DATA"):
            bits = c["connections"].get(pin, [])
            if bits and isinstance(bits[0], int):
                own = [n for n in self.names.get(bits[0], ()) if not n.startswith("$") and n not in self.ports and
                       ((p and n.startswith(p + ".") and "." not in n[len(p) + 1:]) or (not p and "." not in n))]
                if own:                                  # the latest declared: a body register after the ports
                    return max(own, key=lambda n: (self.nline.get(n, 0), -len(n), n))
                if bits[0] in self.netname:
                    return self.netname[bits[0]]
        return cn

    def cdc_scopes(self):
        """Instance paths of the CDC modules, from the netlist's $scopeinfo cells (Yosys flatten keeps them)."""
        return {cn for cn, c in self.cells.items() if c["type"] == "$scopeinfo" and
                str(c.get("attributes", {}).get("module", "")).lstrip("\\") in CDC_MODULES}

    def ctype(self, cn):
        return self.cells[cn]["type"]

    def blackbox(self, cn):
        t = self.ctype(cn)
        return not t.startswith("$") and (t not in self.mods or self.mods[t].get("attributes", {}).get("blackbox"))

    def inputs(self, cn):
        c = self.cells[cn]
        dirs = c.get("port_directions", {})
        for pin, bits in c["connections"].items():
            if dirs.get(pin, "input") == "input":
                for b in bits:
                    if isinstance(b, int):
                        yield pin, b


def clock_root(nl: Netlist, bit, memo):
    """The roots of a clock bit: black-box outputs (cell, pin), top inputs, or register outputs."""
    if bit in memo:
        return memo[bit]
    memo[bit] = frozenset()                              # cycle guard
    roots = set()
    stack, seen = [bit], set()
    while stack:
        b = stack.pop()
        if b in seen:
            continue
        seen.add(b)
        drv = nl.driver.get(b)
        if drv is None:
            roots.add(("const", 0))
            continue
        cn, pin = drv
        if cn.startswith("port:"):
            roots.add((cn, 0))
        elif nl.blackbox(cn):
            roots.add((cn, f"{pin}#{nl.dbit.get(b, 0)}"))   # each output bit its own clock (one PLL: related)
        elif is_seq(nl.ctype(cn)):
            roots.add((cn, "Q"))                         # a divided / register clock
        else:
            for p, ib in nl.inputs(cn):
                stack.append(ib)
    memo[bit] = frozenset(roots)
    return memo[bit]


def seq_clocks(nl: Netlist, cn, memo):
    c = nl.cells[cn]
    con = c["connections"]
    if nl.ctype(cn) in MEM:
        clks = {}
        for pin in ("WR_CLK", "RD_CLK"):
            bits = [b for b in con.get(pin, []) if isinstance(b, int)]
            if bits:
                clks[pin] = frozenset().union(*(clock_root(nl, b, memo) for b in bits))
        return clks
    for pin in CLK_PINS:
        if pin in con:
            bits = [b for b in con[pin] if isinstance(b, int)]
            if bits:
                return {"CLK": clock_root(nl, bits[0], memo)}
    return {}


def name_root(nl, roots):
    out = []
    for cn, pin in sorted(roots, key=str):
        if cn == "const":
            out.append("const")
        elif cn.startswith("port:"):
            out.append(cn[5:])
        else:
            pn, _, k = str(pin).partition("#")
            bits = nl.cells[cn]["connections"].get(pn, [])
            i = int(k) if k else 0
            out.append(nl.clock_name(bits[i]) if i < len(bits) and isinstance(bits[i], int) else cn)
    return "+".join(out) or "none"


def sync_instances(filelist: str) -> list[str]:
    """Patterns for every instance of a CDC module in the sources listed in filelist (one path per line; '#'
    comments). The instances inside a CDC module's own file are covered by the pattern of that module's
    instance."""
    mods = "|".join(CDC_MODULES)
    rx = re.compile(r"\b(" + mods + r")\b\s*(#\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s*(\w+)\s*\(", re.S)
    names = set()
    with open(filelist, encoding="utf-8") as fh:
        files = [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                src = re.sub(r"//[^\n]*", "", fh.read())
        except OSError:
            continue
        if re.search(r"^\s*module\s+(" + mods + r")\b", src, re.M):
            continue
        names |= {m.group(3) for m in rx.finditer(src)}
    return [r"(^|\.)" + re.escape(n) + r"\." for n in sorted(names)]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("json")
    ap.add_argument("--top")
    ap.add_argument("--waive", action="append", default=[], help="regex on 'src -> dst' lines")
    ap.add_argument("--sync-inst", action="append", default=[], help="regex on a destination register's name: a "
                    "synchroniser (a CDC module inlined by sv2v)")
    ap.add_argument("--bb-clock", action="append", default=[], help="MODULE:PIN=CLKPIN: a black box's output PIN is "
                    "registered on its input CLKPIN (e.g. dpll_dco:phase_o=ref_clk)")
    ap.add_argument("--waive-file", help="waivers: one regex on 'src -> dst' lines each, '#' and its reason after it")
    ap.add_argument("--sync-src", help="file listing the design's sources: every instance of a library CDC module "
                    "(CDC_MODULES) is a synchroniser")
    ap.add_argument("--out")
    ap.add_argument("--max", type=int, default=40, help="lines listed per category")
    a = ap.parse_args()
    if a.sync_src:
        a.sync_inst += sync_instances(a.sync_src)
    reasons = []                                         # (regex, reason) of the waiver file
    if a.waive_file:
        with open(a.waive_file, encoding="utf-8") as fh:
            for ln in fh:
                rx, _, why = ln.partition("#")
                if rx.strip():
                    a.waive.append(rx.strip())
                    reasons.append((rx.strip(), why.strip()))
    bbclk = {}
    for spec in a.bb_clock:
        mp, _, ck = spec.partition("=")
        md, _, pn = mp.partition(":")
        bbclk[("\\" + md if not md.startswith("\\") else md, pn)] = ck
        bbclk[(md.lstrip("\\"), pn)] = ck
    mods, top = load(a.json, a.top)
    nl = Netlist(mods, top)
    memo = {}
    clk_of = {}                                          # sequential cell -> its (data) clock roots
    for cn in nl.cells:
        if is_seq(nl.ctype(cn)):
            cl = seq_clocks(nl, cn, memo)
            if cl:
                clk_of[cn] = cl
    clock_bits = set()
    for cn in clk_of:
        con = nl.cells[cn]["connections"]
        for pin in CLK_PINS + ("WR_CLK", "RD_CLK"):
            clock_bits |= {b for b in con.get(pin, []) if isinstance(b, int)}

    def src_dom(cn):
        cl = clk_of[cn]
        return cl.get("CLK") or cl.get("WR_CLK") or frozenset()

    CAP = 4                                              # source registers counted per cone (glitch warning)
    cmemo = {}

    def cone(bit):
        """The sources of a data bit, memoised over the combinational graph (each bit once): {source clock
        domain: an example source cell}, the top input ports, the source cells counted up to CAP, and whether
        the cone has a cell with several inputs (logic that can mix them)."""
        if bit in cmemo:
            return cmemo[bit]
        stack = [(bit, False)]
        while stack:
            b, done = stack.pop()
            if b in cmemo and not done:
                continue
            drv = nl.driver.get(b)
            if drv is None:
                cmemo[b] = ({}, frozenset(), frozenset(), False)
                continue
            cn, pin = drv
            if cn.startswith("port:"):
                cmemo[b] = ({}, frozenset({cn[5:]}), frozenset(), False)
                continue
            if cn in clk_of or nl.blackbox(cn):
                if cn in clk_of:
                    d = src_dom(cn)
                elif (nl.ctype(cn), pin) in bbclk:       # a black-box output in the domain of one of its clocks
                    cb = [x for x in nl.cells[cn]["connections"].get(bbclk[(nl.ctype(cn), pin)], []) if isinstance(x, int)]
                    d = clock_root(nl, cb[0], memo) if cb else frozenset({(cn, "out")})
                else:
                    d = frozenset({(cn, "out")})
                cmemo[b] = ({d: cn}, frozenset(), frozenset({cn}), False)
                continue
            ins = [ib for _, ib in nl.inputs(cn)]
            if not done:
                cmemo[b] = None                          # in progress (a combinational loop reads it as empty)
                stack.append((b, True))
                stack.extend((ib, False) for ib in ins if ib not in cmemo)
                continue
            doms, ports, srcs, gates = {}, set(), set(), len(ins) > 1
            for ib in ins:
                r = cmemo.get(ib)
                if r is None:
                    continue
                for k, v in r[0].items():
                    doms.setdefault(k, v)
                ports |= r[1]
                if len(srcs) < CAP:
                    srcs |= set(list(r[2])[:CAP - len(srcs)])
                gates = gates or r[3]
            cmemo[b] = (doms, frozenset(ports), frozenset(srcs), gates)
        r = cmemo[bit]
        return r if r is not None else ({}, frozenset(), frozenset(), False)

    allowed, related, viol, warn, held = [], [], [], [], []
    scopes = nl.cdc_scopes()

    def in_sync(cn):
        """The cell lies in a CDC block: its tag, a synchroniser stage marked async_reg (its output net), its
        instance path under a CDC module's ($scopeinfo), or the path / its own name matched by a --sync-inst /
        --sync-src pattern."""
        if "cdc_sync" in nl.cells[cn].get("attributes", {}):
            return True
        if any(n in nl.async_nets for n in nl.onames(cn)):
            return True
        p = nl.path(cn)
        if any(p == sc or p.startswith(sc + ".") for sc in scopes):
            return True
        return any(re.search(r, p + ".") or re.search(r, nl.dname(cn)) for r in a.sync_inst)
    ext = defaultdict(set)
    for dst, cl in clk_of.items():
        c = nl.cells[dst]
        dn = nl.dname(dst)
        sync = in_sync(dst)
        con = c["connections"]
        if nl.ctype(dst) in MEM:
            groups = [("WR", cl.get("WR_CLK"), [p for p in con if p.startswith("WR_") and p != "WR_CLK"]),
                      ("RD", cl.get("RD_CLK"), [p for p in con if p in ("RD_ADDR", "RD_EN", "RD_SRST", "RD_ARST")])]
        else:
            groups = [("", cl.get("CLK"), [p for p in con if p in DATA_PINS])]
        for tag, dom, pins in groups:
            if not dom:
                continue
            for pin in pins:
                bits = [b for b in con[pin] if isinstance(b, int)]
                for b in bits:
                    if b in clock_bits:
                        continue
                    sdoms, ports, srcs, gates = cone(b)
                    for pt in ports:
                        ext[pt].add(dst)
                    for sd, s in sdoms.items():
                        if sd == dom or not sd:
                            continue
                        sn = nl.dname(s) if s in clk_of else s
                        line = f"{sn} [{name_root(nl, sd)}] -> {dn}.{pin} [{name_root(nl, dom)}]"
                        if any(re.search(w, line) for w in a.waive):
                            allowed.append(line + "  (waived)")
                        elif sync:
                            allowed.append(line)
                            # only registers of other domains can glitch at this clock's edge (a synchronous
                            # reset or enable of the destination's own domain is settled by then)
                            foreign = [x for x in srcs if x not in clk_of or src_dom(x) != dom]
                            if gates and len(bits) == 1 and len(foreign) > 1:
                                warn.append(line + f"  (logic mixing {len(foreign)}{'+' if len(srcs) >= CAP else ''} "
                                            "source registers)")
                        elif s in nl.cells and in_sync(s):
                            held.append(line)          # (stable across the handshake: no glitch to capture)
                        elif {r[0] for r in sd} == {r[0] for r in dom} and all(not r[0].startswith("port:") for r in sd):
                            related.append(line)
                        else:
                            viol.append(line)
    doms = defaultdict(int)
    for cn, cl in clk_of.items():
        for v in cl.values():
            doms[name_root(nl, v)] += 1
    rep = [f"CDC check of {top} ({a.json}): {len(clk_of)} sequential cells"]
    rep.append("Clock roots (sequential cells):")
    rep += [f"  {n}: {k}" for n, k in sorted(doms.items(), key=lambda x: -x[1])]

    def listing(title, items):
        uniq = sorted(set(items))
        rep.append(f"{title}: {len(uniq)}")
        rep.extend("  " + x for x in uniq[:a.max])
        if len(uniq) > a.max:
            rep.append(f"  ... {len(uniq) - a.max} more")
    listing("VIOLATIONS (unsynchronised crossings)", viol)
    if reasons:
        rep.append(f"Waivers: {len(reasons)}")
        rep.extend(f"  {rx}  - {why}" for rx, why in reasons)
    listing("Warnings (logic before a synchroniser)", warn)
    listing("Held data of CDC blocks (handshake / FIFO memory)", held)
    listing("Related clocks (same oscillator)", related)
    listing("Synchronised crossings", allowed)
    rep.append(f"External inputs (board): {len(ext)}")
    rep.extend(f"  {p}: {len(d)} destinations" for p, d in sorted(ext.items())[:a.max])
    rep.append("CDC CHECK " + ("FAIL" if viol else "PASS"))
    text = "\n".join(rep)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    sys.exit(1 if viol else 0)


if __name__ == "__main__":
    main()
