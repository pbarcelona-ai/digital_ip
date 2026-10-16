#!/usr/bin/env python3
# ***************
# Filename: sv_annotate.py
# Author: FPGA Cores 4 U
# Description: Adds the interface annotation of one port group to a module
#   header and gathers the group's ports under it (the form sv_ifconv.py
#   converts):  // <group>: <iface>.<modport> (<interface file>)[, K = V] [{port=member ...}]
#   The group is chosen by an explicit port -> member map (--map), by port
#   names equal to the member names (--same, register interfaces cfg_* /
#   sts_*), or by the prefix <group>_<member> (default). Re-running on an
#   annotated group does nothing. Usage:
#     sv_annotate.py FILE MODULE GROUP IFACE.MODPORT [--params "ADDR_W = ADDR_W"]
#                    [--map p=m ...] [--same] [--if-file PATH]
# Date: 2026-10-16
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from sv_ifconv import IFACES, PORT, ROOT, build_table, header_span  # noqa: E402


def fix_commas(lines):
    """Every port line ends with ',' except the last port (trailing comments kept)."""
    idx = [i for i, l in enumerate(lines) if PORT.match(l) or re.match(r"^\s*\w+\.\w+\s+\w+", l)]
    for k, i in enumerate(idx):
        code, sep_, com = lines[i].partition("//")
        c = code.rstrip().rstrip(",")
        pad = len(code) - len(code.rstrip())
        lines[i] = c + ("," if k < len(idx) - 1 else "") + ((" " * max(pad, 1) + "//" + com) if sep_ else "")
    return lines


def annotate(path, mod, group, iface, mp, params="", pmap=None, same=False, if_file=None):
    t = open(path, encoding="utf-8").read()
    span = next(((p0, p1) for name, p0, p1, _, _ in header_span(t) if name == mod), None)
    if span is None:
        sys.exit(f"{path}: no module {mod}")
    a, j = span
    lines = t[a + 1:j].split("\n")
    if any(re.match(rf"^\s*//\s*{group}:\s*{iface}\.", l) for l in lines):
        return f"{os.path.relpath(path, ROOT)}: {group} already annotated"
    members = IFACES.get(iface, {}).get("members", {})

    def chosen(p):
        if pmap:
            return p in pmap
        if same:
            return p in members if members else p.startswith(("cfg_", "sts_"))
        return p.startswith(group + "_") and p[len(group) + 1:] in members

    gl = [(i, l) for i, l in enumerate(lines) if PORT.match(l) and chosen(PORT.match(l).group(3))]
    if pmap:
        missing = set(pmap) - {PORT.match(l).group(3) for _, l in gl}
        if missing:
            sys.exit(f"{path}: ports not found {sorted(missing)}")
    if not gl:
        sys.exit(f"{path}: no ports for group {group}")
    gi = {i for i, _ in gl}
    keep = [l for i, l in enumerate(lines) if i not in gi]
    pos = sum(1 for i in range(gl[0][0]) if i not in gi)
    ind = re.match(r"\s*", gl[0][1]).group(0)
    fpath = if_file or f"ip/shared/src/interfaces/{iface}.sv"
    ann = f"{ind}// {group}: {iface}.{mp} ({fpath}){', ' + params if params else ''}"
    if pmap:
        ann += " {" + " ".join(f"{k}={v}" for k, v in pmap.items()) + "}"
    new = fix_commas(keep[:pos] + [ann] + [l for _, l in gl] + keep[pos:])
    open(path, "w", encoding="utf-8").write(t[:a + 1] + "\n".join(new) + t[j:])
    return f"{os.path.relpath(path, ROOT)}: {group} -> {iface}.{mp} ({len(gl)} ports)"


def main():
    ap = argparse.ArgumentParser(description="Annotate one interface port group of a module.")
    ap.add_argument("file")
    ap.add_argument("module")
    ap.add_argument("group")
    ap.add_argument("iface_mp", help="<interface>.<modport>")
    ap.add_argument("--params", default="")
    ap.add_argument("--map", nargs="*", default=[], help="port=member pairs")
    ap.add_argument("--same", action="store_true", help="ports named like the members (cfg_* / sts_*)")
    ap.add_argument("--if-file", help="interface source path shown in the annotation")
    a = ap.parse_args()
    build_table()                                          # loads the interface definitions
    iface, mp = a.iface_mp.split(".")
    pmap = dict(kv.split("=") for kv in a.map) if a.map else None
    print(annotate(os.path.abspath(a.file), a.module, a.group, iface, mp, a.params, pmap, a.same, a.if_file))


if __name__ == "__main__":
    main()
