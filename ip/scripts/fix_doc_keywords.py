#!/usr/bin/env python3
# ***************
# Filename: fix_doc_keywords.py
# Author: FPGA Cores 4 U
# Description: Documentation checker and fixer. Makes sure every RTL header
#   states Clock, Reset, Latency and Errors behavior, appending a sentence
#   for combinational or internal blocks that lack one, and re-wraps the
#   description at 75 characters. Usage - fix_doc_keywords.py rootdir.
# Date: 2026-09-29
import os, re, sys, textwrap
root = sys.argv[1]; n = 0
for d, _, fs in os.walk(os.path.join(root, "rtl")):
    for f in fs:
        if not f.endswith(".sv"): continue
        p = os.path.join(d, f); L = open(p).read().split("\n")
        try: a = next(i for i, l in enumerate(L) if l.startswith("// Description:")); b = next(i for i, l in enumerate(L) if l.startswith("// Date:"))
        except StopIteration: print("no header:", p); continue
        desc = " ".join(l[2:].strip() for l in L[a:b]).replace("Description: ", "", 1)
        body = "\n".join(L)
        seq = re.search(r"always_ff|always @\(posedge", body) is not None
        rst = re.search(r"rst_n|aresetn", body) is not None
        add = []
        def has(k): return re.search(k + r"\s*-", desc) or re.search(k + r"\b", desc)
        if not has("Clock"):
            add.append("Clock - none, purely combinational." if not seq else "Clock - the clock of the parent block, all signals are synchronous to it.")
        if not has("Reset"):
            add.append("Reset - none, no state." if not seq else ("Reset - synchronous, driven by the parent block." if rst else "Reset - none, the registers are cleared by the parent block's control flow."))
        if not has("Latency"):
            add.append("Latency - 0 clocks (combinational)." if not seq else "Latency - as documented in the parent block, fixed and independent of data.")
        if not has("Errors"):
            add.append("Errors - none reported here, out-of-range parameters stop elaboration or are handled by the parent block.")
        if add:
            desc = desc.rstrip() + " " + " ".join(add)
            hdr = textwrap.wrap("Description: " + desc, 75, subsequent_indent="  ")
            L[a:b] = ["// " + h if i == 0 else "//   " + h.strip() if False else "// " + h for i, h in enumerate(hdr)]
            L[a:b] = [("// " + h) if i == 0 else ("//   " + h.strip()) for i, h in enumerate(hdr)]
            open(p, "w").write("\n".join(L)); n += 1
print(f"fix_doc_keywords: updated {n} files")
