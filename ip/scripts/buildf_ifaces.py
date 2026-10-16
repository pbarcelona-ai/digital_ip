#!/usr/bin/env python3
# ***************
# Filename: buildf_ifaces.py
# Author: FPGA Cores 4 U
# Description: Puts the SystemVerilog interface files a file list needs at
#   its top. For every build.f given, the sources it lists (relative to the
#   IP / design directory, i.e. the parent of scripts/ or tb/scripts/) are
#   scanned for interface ports and instances (<iface>.<modport> name,
#   <iface> #(...) name (), <iface> name ()); each interface is found in
#   ip/shared/src/interfaces/ or as a generated */src/include/<iface>.sv and
#   added (relative path) unless the list - or, for tb/scripts/build.f, the
#   RTL list - already has it. Interfaces used by interfaces are not nested,
#   so one pass is enough.
#   Usage: python3 ip/scripts/buildf_ifaces.py [--check] BUILD.F ...
# Date: 2026-10-16
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKIP = {"build", "sim_out", "obj_dir", "work", "__pycache__"}


def iface_files():
    out = {}
    for base in ("ip", "image_processing"):
        for dp, dn, fn in os.walk(os.path.join(ROOT, base)):
            dn[:] = [d for d in dn if d not in SKIP]
            for f in fn:
                if f.endswith("_if.sv") and not f.startswith("._"):
                    t = open(os.path.join(dp, f), encoding="utf-8").read()
                    m = re.search(r"^\s*interface\s+(\w+)", t, re.M)
                    if m:
                        out[m.group(1)] = os.path.join(dp, f)
    return out


def entries(bf):
    """(base directory the entries are relative to, lines, entries). Library lists are relative to the
    IP directory; the scaler family's tb/build.f to tb/ and scripts/build.f to src/: the base is the
    candidate under which most entries exist."""
    lines = open(bf, encoding="utf-8").read().split("\n")
    files = [l.strip() for l in lines if l.strip() and not l.strip().startswith(("#", "//", "+", "-"))]
    d = os.path.dirname(bf)
    ip = os.path.dirname(d) if os.path.basename(d) in ("scripts", "tb") else d
    if os.path.basename(ip) == "tb":
        ip = os.path.dirname(ip)
    cands = [ip, d, os.path.join(ip, "src"), os.path.join(ip, "tb")]
    base = max(cands, key=lambda b: sum(os.path.isfile(os.path.join(b, f)) for f in files))
    return base, lines, files


def used(paths, known):
    names = set()
    for p in paths:
        if not os.path.isfile(p):
            continue
        t = re.sub(r"//[^\n]*", "", open(p, encoding="utf-8", errors="replace").read())
        for n in known:
            if re.search(rf"(?m)(^\s*{n}\.\w+\s+\w+|\b{n}\s*(#\s*\(.*?\))?\s*\w+\s*(\[[^\]]*\])?\s*\(\s*\))", t, re.S):
                names.add(n)
    return names


def main():
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    known = iface_files()
    bad = 0
    for bf in args:
        bf = os.path.abspath(bf)
        base, lines, files = entries(bf)
        paths = [os.path.normpath(os.path.join(base, f)) for f in files]
        have = set(paths)
        if os.path.basename(os.path.dirname(os.path.dirname(bf))) == "tb":
            rtl = os.path.join(base, "scripts", "build.f")
            if os.path.isfile(rtl):
                b2, _, f2 = entries(rtl)
                have |= {os.path.normpath(os.path.join(b2, f)) for f in f2}
        need = sorted(n for n in used(paths, known) if known[n] not in have and known[n] not in paths)
        if not need:
            continue
        add = [os.path.relpath(known[n], base) for n in need]
        if check:
            print(f"{os.path.relpath(bf, ROOT)}: missing {', '.join(add)}")
            bad += 1
            continue
        hdr = 0                                    # after comments and packages (an interface may use them)
        while hdr < len(lines) and (lines[hdr].startswith(("#", "//")) or not lines[hdr].strip()
                                    or lines[hdr].strip().endswith("_pkg.sv")):
            hdr += 1
        lines[hdr:hdr] = add
        open(bf, "w", encoding="utf-8").write("\n".join(lines))
        print(f"{os.path.relpath(bf, ROOT)}: + {', '.join(add)}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
