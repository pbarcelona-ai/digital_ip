#!/usr/bin/env python3
# ***************
# Filename: add_headers.py
# Author: FPGA Cores 4 U
# Description: Converts a first-line //DESC: comment in every .sv file into
#   the standard file header (Filename, Author, wrapped Description, Date).
#   Usage - add_headers.py rootdir.
# Date: 2026-09-29
import sys, os, re, textwrap, datetime
DATE = "2026-09-29"
def header(fname, desc):
    out = ["// ***************", f"// Filename: {fname}", "// Author: FPGA Cores 4 U"]
    lines = textwrap.wrap(desc, width=75, initial_indent="// Description: ",
                          subsequent_indent="//   ")
    out += lines + [f"// Date: {DATE}"]
    assert all(len(l) <= 75 for l in out), out
    return "\n".join(out) + "\n"
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if not f.endswith(".sv"): continue
        p = os.path.join(root, f)
        txt = open(p).read()
        m = re.match(r"//DESC: (.*)\n", txt)
        if m:
            open(p, "w").write(header(f, m.group(1)) + txt[m.end():])
