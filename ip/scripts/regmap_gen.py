#!/usr/bin/env python3
# ***************
# Filename: regmap_gen.py
# Author: Paul Barcelona
# Description: Register map generator. Reads a JSON register description and
#   writes a synthesizable AXI4-Lite register block (SystemVerilog wrapper
#   around axi4_lite_regs with named ports), a C header with offsets and
#   field masks, and a Markdown register table. Access types RW, RO, W1C
#   and W1S are supported. Usage - regmap_gen.py map.json outdir.
# Date: 2026-09-29
import json, sys, os, textwrap, datetime

ACC = {"RW": 0, "RO": 1, "W1C": 2, "W1S": 3}
DATE = datetime.date.today().isoformat()

def header(fname, desc, comment="//"):
    out = [f"{comment} ***************", f"{comment} Filename: {fname}", f"{comment} Author: Paul Barcelona"]
    lines = textwrap.wrap("Description: " + desc, 75, subsequent_indent="  ")
    out += [f"{comment} {l}" for l in lines]
    out.append(f"{comment} Date: {DATE}")
    return "\n".join(out) + "\n"

def load(path):
    m = json.load(open(path))
    for k in ("name", "registers"):
        if k not in m: sys.exit(f"regmap_gen: missing '{k}'")
    regs = m["registers"]
    names = set()
    for i, r in enumerate(regs):
        for k in ("name", "access"):
            if k not in r: sys.exit(f"regmap_gen: register {i} lacks '{k}'")
        if r["access"] not in ACC: sys.exit(f"regmap_gen: {r['name']}: access must be one of {list(ACC)}")
        if r["name"] in names: sys.exit(f"regmap_gen: duplicate register {r['name']}")
        names.add(r["name"])
        r["offset"] = int(str(r.get("offset", i * 4)), 0)
        if r["offset"] != i * 4: sys.exit(f"regmap_gen: {r['name']}: offsets must be dense (expected 0x{i*4:X})")
        r["reset"] = int(str(r.get("reset", 0)), 0) & 0xFFFFFFFF
        used = 0
        for f in r.get("fields", []):
            lo = f["bit"] if isinstance(f["bit"], int) else int(str(f["bit"]).split(":")[1])
            hi = f["bit"] if isinstance(f["bit"], int) else int(str(f["bit"]).split(":")[0])
            if not (0 <= lo <= hi <= 31): sys.exit(f"regmap_gen: {r['name']}.{f['name']}: bad bit range")
            mask = ((1 << (hi - lo + 1)) - 1) << lo
            if used & mask: sys.exit(f"regmap_gen: {r['name']}.{f['name']} overlaps another field")
            used |= mask; f["lo"], f["hi"], f["mask"] = lo, hi, mask
    return m

def gen_sv(m):
    n = m["name"]; regs = m["registers"]; N = len(regs); aw = m.get("addr_width", max(4, (N * 4 - 1).bit_length()))
    if N * 4 > (1 << aw): sys.exit("regmap_gen: addr_width too small")
    ports = []
    for r in regs:
        rn = r["name"].lower(); a = r["access"]
        if a == "RO": ports.append(f"  input  logic [31:0] {rn}_i,        // {r['name']} (RO): value read by software")
        else: ports.append(f"  output logic [31:0] {rn}_o,        // {r['name']} ({a}): register value")
        if a == "W1C": ports.append(f"  input  logic [31:0] {rn}_set_i,    // {r['name']}: hardware sets bits (1 clock pulses)")
        if a == "W1S": ports.append(f"  input  logic [31:0] {rn}_clr_i,    // {r['name']}: hardware clears bits (1 clock pulses)")
        ports.append(f"  output logic        {rn}_wr_o,       // {r['name']}: pulse on every software write")
    accv = sum(ACC[r["access"]] << (2 * i) for i, r in enumerate(regs))
    rstv = sum(r["reset"] << (32 * i) for i, r in enumerate(regs))
    desc = (f"Generated AXI4-Lite register block '{n}' with {N} registers (regmap_gen.py, do not edit by hand; "
            f"regenerate from the JSON description). Version 1.0.0. Built on axi4_lite_regs, so the timing is "
            f"the same. Clock - aclk. Reset - synchronous aresetn, registers take their documented reset values. "
            f"Latency - write 4 clocks, read 4 clocks. Errors - writes to RO registers answer SLVERR, addresses beyond "
            f"the last register answer DECERR. Access types - RW read/write with byte strobes, RO read only, W1C "
            f"hardware sets and software clears by writing 1, W1S software sets and hardware clears.")
    s = header(f"{n}.sv", desc)
    s += f"module {n} (\n  input  logic        aclk,\n  input  logic        aresetn,\n"
    s += "  input  logic [%d:0]  s_axil_awaddr,\n  input  logic        s_axil_awvalid,\n  output logic        s_axil_awready,\n" % (aw - 1)
    s += "  input  logic [31:0] s_axil_wdata,\n  input  logic [3:0]  s_axil_wstrb,\n  input  logic        s_axil_wvalid,\n  output logic        s_axil_wready,\n"
    s += "  output logic [1:0]  s_axil_bresp,\n  output logic        s_axil_bvalid,\n  input  logic        s_axil_bready,\n"
    s += "  input  logic [%d:0]  s_axil_araddr,\n  input  logic        s_axil_arvalid,\n  output logic        s_axil_arready,\n" % (aw - 1)
    s += "  output logic [31:0] s_axil_rdata,\n  output logic [1:0]  s_axil_rresp,\n  output logic        s_axil_rvalid,\n  input  logic        s_axil_rready,\n"
    s += "\n".join(ports).rstrip(",") + "\n);\n"
    s = s.replace(",        //", "        //") if False else s
    # fix trailing commas: every port line ends with a comma except the last
    lines = s.split("\n"); idx = [i for i, l in enumerate(lines) if l.startswith("  output logic        ") and l.endswith("") and ")" not in l]
    s = "\n".join(lines)
    s += f"  localparam logic [31:0] IP_VERSION = 32'h0001_0000;\n"
    s += f"  localparam int NREG = {N};\n"
    s += f"  localparam logic [2*NREG-1:0]  ACCESS     = {2*N}'h{accv:X};\n"
    s += f"  localparam logic [32*NREG-1:0] RESET_VALS = {32*N}'h{rstv:X};\n"
    s += "  logic [32*NREG-1:0] hw, hwset, regv; logic [NREG-1:0] wrp;\n"
    s += "  always_comb begin\n    hw = '0; hwset = '0;\n"
    for i, r in enumerate(regs):
        rn = r["name"].lower()
        if r["access"] == "RO": s += f"    hw[{i}*32 +: 32] = {rn}_i;\n"
        if r["access"] == "W1C": s += f"    hwset[{i}*32 +: 32] = {rn}_set_i;\n"
        if r["access"] == "W1S": s += f"    hwset[{i}*32 +: 32] = {rn}_clr_i;\n"
    s += "  end\n"
    s += (f"  axi4_lite_regs #(.ADDR_W({aw}), .NREG(NREG), .ACCESS(ACCESS), .RESET_VALS(RESET_VALS)) u_regs (\n"
          "    .aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,\n"
          "    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp,\n"
          "    .s_axil_rvalid, .s_axil_rready, .hw_i(hw), .hw_set_i(hwset), .reg_o(regv), .wr_pulse_o(wrp));\n")
    for i, r in enumerate(regs):
        rn = r["name"].lower()
        if r["access"] != "RO": s += f"  assign {rn}_o = regv[{i}*32 +: 32];\n"
        s += f"  assign {rn}_wr_o = wrp[{i}];\n"
    s += "endmodule\n"
    return s

def fix_commas(sv):
    # port list: add commas to every port line except the last one before ');'
    out = sv.split("\n"); start = next(i for i, l in enumerate(out) if l.startswith("module "))
    end = next(i for i, l in enumerate(out) if l.strip() == ");")
    port_idx = [i for i in range(start + 1, end) if out[i].strip().startswith(("input", "output"))]
    for k, i in enumerate(port_idx):
        line = out[i]
        code, _, cmt = line.partition("//")
        code = code.rstrip().rstrip(",")
        if k != len(port_idx) - 1: code += ","
        out[i] = code + (("   //" + cmt) if cmt else "")
    return "\n".join(out)

def gen_h(m):
    n = m["name"].upper(); s = header(f"{m['name']}.h", f"C header for register block {m['name']} (generated by regmap_gen.py): byte offsets, reset values and field masks.", "//")
    s += f"#ifndef {n}_H\n#define {n}_H\n"
    for r in m["registers"]:
        rn = r["name"].upper()
        s += f"#define {n}_{rn}_OFFSET 0x{r['offset']:02X}u   /* {r['access']} */\n#define {n}_{rn}_RESET 0x{r['reset']:08X}u\n"
        for f in r.get("fields", []):
            fn = f["name"].upper()
            s += f"#define {n}_{rn}_{fn}_SHIFT {f['lo']}u\n#define {n}_{rn}_{fn}_MASK 0x{f['mask']:08X}u\n"
    return s + f"#endif /* {n}_H */\n"

def gen_md(m):
    s = f"# {m['name']} register map\n\n{m.get('desc', '')}\n\n| Offset | Name | Access | Reset | Description |\n|---|---|---|---|---|\n"
    for r in m["registers"]:
        s += f"| 0x{r['offset']:02X} | {r['name']} | {r['access']} | 0x{r['reset']:08X} | {r.get('desc', '')} |\n"
    for r in m["registers"]:
        if r.get("fields"):
            s += f"\n### {r['name']} (0x{r['offset']:02X})\n\n| Bits | Field | Description |\n|---|---|---|\n"
            for f in r["fields"]:
                b = f"{f['hi']}:{f['lo']}" if f["hi"] != f["lo"] else f"{f['lo']}"
                s += f"| {b} | {f['name']} | {f.get('desc', '')} |\n"
    return s

if __name__ == "__main__":
    if len(sys.argv) != 3: sys.exit("usage: regmap_gen.py map.json outdir")
    m = load(sys.argv[1]); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
    open(f"{out}/{m['name']}.sv", "w").write(fix_commas(gen_sv(m)))
    open(f"{out}/{m['name']}.h", "w").write(gen_h(m))
    open(f"{out}/{m['name']}.md", "w").write(gen_md(m))
    print(f"regmap_gen: wrote {m['name']}.sv/.h/.md to {out}")
