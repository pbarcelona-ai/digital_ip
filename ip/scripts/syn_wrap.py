#!/usr/bin/env python3
# ***************
# Filename: syn_wrap.py
# Author: FPGA Cores 4 U
# Description: Writes a synthesis wrapper <top>_syn for a module whose ports
#   include SystemVerilog interfaces. Yosys (native reader, read_slang and
#   sv2v) cannot elaborate a top-level module with interface ports, so the
#   wrapper exposes every interface port as discrete ports named
#   <port>_<member> (the comment above each group names the interface, as
#   the library rule requires for tools without interface support),
#   instantiates the interfaces with the widths of the port's annotation
#   ("// s_axis: axis_if.slave (...), DATA_W = 24") and connects the top.
#   Plain ports and parameters are passed through unchanged.
#   Usage: syn_wrap.py <source of top> <top> <interface sources...> > <top>_syn.sv
#   Exit status 1 (no output) when the top has no interface port.
# Date: 2026-10-16
import re
import sys


def mask_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), s, flags=re.S)
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), s)


def interfaces(paths: list[str]) -> dict:
    """{name: {"params": {P: default}, "members": [(name, range)], "modports": {mp: {member: dir}}}}"""
    out = {}
    for p in paths:
        s = mask_comments(open(p).read())
        for im in re.finditer(r"\binterface\s+(\w+)\s*(#\s*\((.*?)\))?\s*\(\s*\)\s*;(.*?)\bendinterface", s, re.S):
            params = {}
            for pm in re.finditer(r"parameter\s+(?:\w+\s+)?(\w+)\s*=\s*([^,]+?)\s*(?=,\s*parameter|$)",
                                  (im.group(3) or "").strip(), re.S):
                params[pm.group(1)] = pm.group(2).strip()
            body = im.group(4)
            members = [(m.group(3), (m.group(2) or "").strip())
                       for m in re.finditer(r"^\s*(logic|wire)\s*((?:\[[^\]]*\]\s*)*)(\w+)\s*;", body, re.M)]
            modports = {}
            for mp in re.finditer(r"modport\s+(\w+)\s*\(([^;]*)\)\s*;", body):
                dirs, d = {}, None
                for tok in re.split(r"[\s,]+", mp.group(2)):
                    if tok in ("input", "output", "inout"):
                        d = tok
                    elif tok and d:
                        dirs[tok] = d
                modports[mp.group(1)] = dirs
            out[im.group(1)] = {"params": params, "members": members, "modports": modports}
    return out


def subst(expr: str, values: dict) -> str:
    for k in sorted(values, key=len, reverse=True):
        expr = re.sub(rf"\b{k}\b", f"({values[k]})", expr)
    return expr


def main() -> int:
    src, top, ifsrc = sys.argv[1], sys.argv[2], sys.argv[3:]
    ifs = interfaces(ifsrc)
    text = open(src).read()
    mk = mask_comments(text)
    m = re.search(rf"\bmodule\s+{top}\b\s*(#\s*\()?", mk)
    if not m:
        return 1
    i = m.end()
    params_txt = ""
    if m.group(1):
        depth, j = 1, i
        while depth:
            depth += {"(": 1, ")": -1}.get(mk[j], 0)
            j += 1
        params_txt = text[i:j - 1]
        i = j
    p0 = mk.index("(", i)
    depth, j = 0, p0
    while True:
        depth += {"(": 1, ")": -1}.get(mk[j], 0)
        if depth == 0:
            break
        j += 1
    ports_txt = text[p0 + 1:j]
    pnames = [pm.group(1) for pm in re.finditer(r"parameter\s+(?:\w+\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*=",
                                                  mask_comments(params_txt))]
    lines, conns, body, ann = [], [], [], None
    found = False
    for raw in ports_txt.split("\n"):
        code = raw.split("//")[0].strip().rstrip(",").strip()
        am = re.match(r"^\s*//\s*(\w+):\s*(\w+)\.(\w+)\s*\(([^)]*)\)(.*)$", raw)
        if am:
            ann = am
            continue
        im = re.match(r"^(\w+)\.(\w+)\s+(\w+)$", code)
        if im and im.group(1) in ifs:
            found = True
            ifn, mp, pn = im.groups()
            info = ifs[ifn]
            vals = dict(info["params"])
            pover = {}
            if ann and ann.group(1) == pn:
                for kv in re.finditer(r"(\w+)\s*=\s*([^,{]+)", ann.group(5)):
                    if kv.group(1) in vals:
                        pover[kv.group(1)] = kv.group(2).strip()
                        vals[kv.group(1)] = kv.group(2).strip()
            # resolve defaults that refer to other interface parameters (e.g. KEEP_W from DATA_W)
            for _ in range(3):
                vals = {k: subst(v, {kk: vv for kk, vv in vals.items() if kk != k and kk in info["params"]})
                        if k not in pover else v for k, v in vals.items()}
            lines.append(f"  // {pn}: {ifn}.{mp} (discrete for synthesis)")
            dirs = info["modports"].get(mp, {})
            for mem, rng in info["members"]:
                d = dirs.get(mem)
                if d is None:
                    continue
                r = subst(rng, vals) if rng else ""
                lines.append(f"  {d:6} logic {r + ' ' if r else ''}{pn}_{mem},")
                if d == "input":
                    body.append(f"  assign {pn}_if.{mem} = {pn}_{mem};")
                else:
                    body.append(f"  assign {pn}_{mem} = {pn}_if.{mem};")
            ps = ", ".join(f".{k}({v})" for k, v in pover.items())
            body.insert(0, f"  {ifn}{' #(' + ps + ')' if ps else ''} {pn}_if ();")
            conns.append(f"    .{pn}({pn}_if)")
            ann = None
            continue
        pm = re.match(r"^(input|output|inout)\b.*?(\w+)$", code)
        if pm:
            lines.append("  " + code + ",")
            conns.append(f"    .{pm.group(2)}")
        if code:
            ann = None
    if not found:
        return 1
    lines[-1] = lines[-1].rstrip(",")
    out = [f"// {top}_syn: generated by ip/scripts/syn_wrap.py - discrete-port synthesis wrapper of {top}",
           f"module {top}_syn" + (f" #({params_txt.rstrip()}\n)" if params_txt.strip() else "") + " (",
           *lines, ");", *body,
           f"  {top}" + (" #(" + ", ".join(f".{p}({p})" for p in pnames) + ")" if pnames else "") + " u_top (",
           ",\n".join(conns), "  );", "endmodule", ""]
    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
