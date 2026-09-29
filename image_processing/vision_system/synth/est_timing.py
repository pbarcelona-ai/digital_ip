#!/usr/bin/env python3
# ***************
# Filename: est_timing.py
# Author: Paul Barcelona
# Description: Estimates worst register-to-register path delay from a
# Yosys-synthesized Xilinx netlist (synth_netlist.json). Yosys ships no
# Xilinx cell-delay library, so this applies an explicit, editable
# per-cell delay model (below). It is a PROXY for static timing, not a
# substitute for place-and-route STA: it ignores real routing.
# Date: September 26, 2026
# ***************
"""Usage: est_timing.py synth_netlist.json [clock_period_ns=10.0] [--brief] [--strict]

  --brief   print one line: "<worst module> <delay ns> <slack ns>"
  --strict  exit status 1 if any module has negative slack (used by CI)

Delay model (ns, ~Artix-7 speed grade -1, average routing folded in):
  FF clk->Q .45   FF setup .10        LUT1-6 .65 per level
  CARRY4 .35      MUXF7/F8 .30        INV .10
  DSP48E1: combinational A/B->P 4.0, C->P 2.0, PCIN->P 1.5; if MREG=1 the path ends at the
  multiplier input (2.6 setup) and restarts at M->P (1.8 + .45);
  if PREG=1 output restarts at clk->P (.55). IBUF/OBUF/BUFG are path
  boundaries (module I/O timing is set by the enclosing design).
  RAMB: clk->DO 2.0 (start), address/data/enable setup 0.8 (endpoint).
"""
import json, sys, collections

LUT_D, CARRY_D, MUXF_D, INV_D = 0.65, 0.35, 0.30, 0.10
FF_CQ, FF_SU = 0.45, 0.10
RAM_CQ, RAM_SU = 2.0, 0.8
DSP_IN_TO_M, DSP_M_TO_P, DSP_CQ = 2.6, 1.8, 0.55
# Unregistered DSP48E1 input->P delays by port (ns): the multiplier path
# (A/B/D) is slow; the C port and the dedicated PCIN cascade are fast.
DSP_PORT_D = {'A': 4.0, 'B': 4.0, 'D': 4.4, 'C': 2.0, 'PCIN': 1.5, 'ACIN': 3.0, 'BCIN': 3.0}

def cell_kind(t):
    if t.startswith("FD") or t.startswith("LD"): return "ff"
    if t.startswith("LUT"): return "lut"
    if t == "CARRY4": return "carry"
    if t.startswith("MUXF"): return "muxf"
    if t == "INV": return "inv"
    if t == "DSP48E1": return "dsp"
    if t in ("IBUF", "OBUF", "BUFG"): return "io"
    if t.startswith("RAMB"): return "ram"
    return "other"

def analyze(mod, mods):
    cells = mod["cells"]
    drivers = {}            # bit -> (cellname, port)
    for cn, c in cells.items():
        for pn, bits in c["connections"].items():
            if c["port_directions"].get(pn) == "output":
                for b in bits:
                    if isinstance(b, int): drivers[b] = (cn, pn)
    arrival = {}            # bit -> (delay, path list)
    def at_bit(b, stack):
        if not isinstance(b, int): return (0.0, [])
        if b in arrival: return arrival[b]
        if b not in drivers: arrival[b] = (0.0, []); return arrival[b]
        cn, pn = drivers[b]
        c = cells[cn]; k = cell_kind(c["type"]); p = c["parameters"]
        if k in ("ff", "io", "ram", "other"):
            d = FF_CQ if k == "ff" else (RAM_CQ if k == "ram" else 0.0)
            arrival[b] = (d, [f"{c['type']}:{cn}"]); return arrival[b]
        if k == "dsp":
            preg = int(p.get("PREG", "0"), 2); mreg = int(p.get("MREG", "0"), 2)
            if preg: arrival[b] = (DSP_CQ, [f"DSP48E1(PREG):{cn}"]); return arrival[b]
            if mreg:
                arrival[b] = (DSP_M_TO_P + FF_CQ, [f"DSP48E1(MREG):{cn}"]); return arrival[b]
        # combinational cell: worst input arrival + own delay
        if b in stack: return (0.0, [])
        worst = (0.0, [])
        for ip, ibits in c["connections"].items():
            if c["port_directions"].get(ip) != "input": continue
            pd = DSP_PORT_D.get(ip, 1.0) if k == "dsp" else 0.0
            for ib in ibits:
                a = at_bit(ib, stack | {b})
                if a[0] + pd > worst[0]: worst = (a[0] + pd, a[1])
        dly = {"lut": LUT_D, "carry": CARRY_D, "muxf": MUXF_D, "inv": INV_D,
               "dsp": 0.0}[k]
        arrival[b] = (worst[0] + dly, worst[1] + [f"{c['type']}"]); return arrival[b]
    worst_total, worst_path = 0.0, []
    for cn, c in cells.items():
        k = cell_kind(c["type"]); p = c["parameters"]
        if k == "ff":
            for ip, ibits in c["connections"].items():
                if c["port_directions"].get(ip) != "input" or ip in ("C", "CLK"): continue
                for ib in ibits:
                    d, path = at_bit(ib, frozenset())
                    if d + FF_SU > worst_total: worst_total, worst_path = d + FF_SU, path + [f"-> {c['type']}:{cn}.{ip}"]
        elif k == "ram":
            for ip, ibits in c["connections"].items():
                if c["port_directions"].get(ip) != "input" or ip.startswith("CLK"): continue
                for ib in ibits:
                    d, path = at_bit(ib, frozenset())
                    if d + RAM_SU > worst_total: worst_total, worst_path = d + RAM_SU, path + [f"-> {c['type']} pin {ip}:{cn}"]
        elif k == "dsp" and (int(p.get("MREG", "0"), 2) or int(p.get("PREG", "0"), 2)):
            for ip, ibits in c["connections"].items():
                if c["port_directions"].get(ip) != "input" or ip not in ("A", "B", "C", "D"): continue
                for ib in ibits:
                    d, path = at_bit(ib, frozenset())
                    if d + DSP_IN_TO_M > worst_total: worst_total, worst_path = d + DSP_IN_TO_M, path + [f"-> DSP48E1 input {ip}:{cn}"]
    return worst_total, worst_path

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    brief = "--brief" in sys.argv
    strict = "--strict" in sys.argv
    with open(args[0]) as fh:
        js = json.load(fh)
    period = float(args[1]) if len(args) > 1 else 10.0
    mods = js["modules"]
    rows = []
    for name, m in mods.items():
        if not m["cells"] or name.startswith("\\") or name.isupper() or name[0].isupper():
            continue   # skip Xilinx primitive/library stubs
        d, path = analyze(m, mods)
        rows.append((d, name, path))
    rows.sort(reverse=True)
    failed = any(period - d < 0 for d, _, _ in rows)
    if brief:
        if rows:
            d, name, _ = rows[0]
            print(f"{name[:40]} {d:.2f} {period - d:.2f}")
    else:
        print(f"Estimated worst reg-to-reg path per module (period target {period:.1f} ns):")
        print(f"{'module':52s} {'delay ns':>9s} {'slack ns':>9s}")
        for d, name, path in rows:
            short = name if len(name) < 50 else name[:47] + "..."
            print(f"{short:52s} {d:9.2f} {period - d:9.2f}  {'OK' if period - d >= 0 else 'FAIL'}")
        if rows:
            d, name, path = rows[0]
            comp = collections.Counter(p.split(":")[0] for p in path)
            print(f"\nCritical path in worst module ({name[:40]}): {d:.2f} ns")
            print("  cell mix along path:", dict(comp))
            print("  start:", path[0] if path else "-", "\n  end:  ", path[-1] if path else "-")
    global _EXIT
    _EXIT = 1 if (strict and failed) else 0

_EXIT = 0

if __name__ == "__main__":
    import threading
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(512 * 1024 * 1024)   # deep combinational cones recurse deeply
    t = threading.Thread(target=main); t.start(); t.join()
    sys.exit(_EXIT)
