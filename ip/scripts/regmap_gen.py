#!/usr/bin/env python3
# ***************
# Filename: regmap_gen.py
# Author: FPGA Cores 4 U
# Description: Register map generator, version 2.0. Reads an IP's JSON
#   register description (src/include/<ip>_regs.json) and writes, next to it
#   in src/include/ (the IP's register-map files together),
#     <name>.sv  the IP's AXI4-Lite register slave (axi4_lite_slave front
#                end): the whole register map, the ID block first, with a
#                named port per register towards the IP's logic;
#     <name>.h   C header: byte offsets, reset values, field shifts / masks;
#     <name>.xml IP-XACT (IEEE 1685-2014) component with the memory map (the
#                same map for XML-based tools);
#   and the Markdown register table <name>.md to the IP's docs/; and the IP's
#   wrapper src/<top>.sv ("top", default <ip>_top; "top": false skips it):
#   the AXI4-Lite port and the functional ports, instantiating the register
#   map (u_regs) and the IP's logic (u_core, module "core", default <ip>, in
#   src/<core>.sv). The core's register ports follow the naming convention
#     cfg_<reg>      value of a RW / W1C / W1S / WO / CMD register (input)
#     cfg_<reg>_wr   its write pulse (input, only where the logic uses it)
#     cfg_<reg>_rd   read pulse of an RC register (input)
#     sts_<reg>      value read from a RO / CMD register (output)
#     sts_<reg>_set  W1C bits set by the logic (output)
#     sts_<reg>_clr  W1S bits cleared by the logic (output)
#   (array registers: flattened, [count*width-1:0]); every other core port
#   is a port of the wrapper. The register map's parameters take the
#   wrapper's parameter of the same name, or "regs_params": {"NAME": "expr"};
#   "top_localparams": ["localparam ...;", ...] are added to the wrapper;
#   "top_params": [{"type", "name", "default"}] are wrapper parameters that
#   only the register map uses (reset values); "core_file": path of the
#   core's source relative to the JSON when it is shared with another IP.
#   Every map starts with the ID block: 0x00 ID (4 ASCII characters, first in
#   [31:24]), 0x04 VERSION (ASCII "d.dd"), 0x08 DATE (BCD mm/dd/yyyy),
#   0x0C reserved; the IP's registers follow from 0x10. VERSION and DATE are
#   the IP_VERSION / IP_DATE localparams of the generated file, kept by
#   ip/scripts/stamp_version.py: a regeneration keeps the stamps already in
#   the file (the JSON "version" only seeds a new one).
#   Access types (ports named after the register, lower case):
#     RW   stored, byte strobes, reset value: <n>_o, <n>_wr_o (write pulse)
#     RO   hardware value: <n>_i; writes answer SLVERR
#     W1C  stored, hardware sets (<n>_set_i, wins over a clear in the same
#          clock), software writes 1 to clear: <n>_o, <n>_wr_o
#     W1S  stored, software writes 1 to set, hardware clears (<n>_clr_i):
#          <n>_o, <n>_wr_o
#     WO   write only, reads 0: <n>_o (the data written), <n>_wr_o
#     CMD  reads the hardware value <n>_i, a write gives <n>_wr_o with the
#          data on <n>_o (commands next to their status)
#     RC   read with a side effect: reads the hardware value <n>_i and gives
#          <n>_rd_o, a one-clock pulse in the clock the value is returned
#          (e.g. pop a receive FIFO); writes answer SLVERR (not for arrays)
#   A register may be an array ("count": N or a parameter expression, element
#   i at offset + stride * i, "stride" default 4, "max_count" elements
#   reserved in the map) and narrower than 32 bits
#   ("width"); arrays use flattened ports ([count*width-1:0], wr_o
#   [count-1:0]). Unmapped words below the end of the map read 0 and ignore
#   writes; beyond it the slave answers DECERR (axi4_lite_slave). Latency:
#   write 2 clocks from AW + W to BVALID, read 2 clocks.
# Date: 2026-10-11
# ***************
# Usage: regmap_gen.py MAP.json [OUTDIR] [--doc DIR] [--check]
#   OUTDIR  where <name>.sv, .h and .xml go (default: the JSON's directory,
#           src/include/)
#   --doc   where <name>.md goes (default: the docs/ directory of the IP, the
#           first one found going up from OUTDIR, else OUTDIR)
#   --check write nothing; exit 1 when the .sv on disk differs from what would
#           be generated (stamps ignored)
#
# JSON: {"name": "<ip>_regs", "ip": "<ip>", "id": "ABCD", "version": "1.00",
#        "desc": "...", "addr_width": 8, "clk": "clk", "rst_n": "rst_n",
#        "params": [{"name": "N", "default": 2, "desc": "..."}],
#        "registers": [{"name": "CTRL", "offset": "0x10", "access": "RW",
#                       "width": 32, "reset": "0x0", "count": 1, "max_count": 1,
#                       "desc": "...", "fields": [{"name": "EN", "bit": 0, "desc": "..."}]}]}
import argparse
import datetime
import json
import os
import re
import sys
import textwrap

ACCESS = ("RW", "RO", "W1C", "W1S", "WO", "CMD", "RC")
STAMP_RE = re.compile(r'localparam\s+logic\s*\[31:0\]\s*IP_(VERSION|DATE)\s*=\s*([^;]+);')
ID_BLOCK = [("ID", 0x00, "RO", "IP identifier, 4 ASCII characters (first in [31:24])"),
            ("VERSION", 0x04, "RO", "version, ASCII \"d.dd\" (+0.01 at every source update)"),
            ("DATE", 0x08, "RO", "date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY)")]


def num(v):
    return int(str(v), 0)


def bits(f):
    b = str(f["bit"])
    hi, lo = (b.split(":") + [b])[:2] if ":" in b else (b, b)
    return int(hi), int(lo)


def load(path):
    m = json.load(open(path))
    for k in ("name", "id", "registers"):
        if k not in m:
            sys.exit(f"regmap_gen: {path}: missing '{k}'")
    if len(m["id"]) != 4:
        sys.exit("regmap_gen: id must be 4 characters")
    m.setdefault("version", "1.00")
    if not re.fullmatch(r"\d\.\d\d", m["version"]):
        sys.exit("regmap_gen: version must be \"d.dd\"")
    m.setdefault("clk", "clk")
    m.setdefault("rst_n", "rst_n")
    m.setdefault("params", [])
    used = {}
    names = set()
    end = 0x10
    for r in m["registers"]:
        if r["access"] not in ACCESS:
            sys.exit(f"regmap_gen: {r['name']}: access must be one of {ACCESS}")
        if r["name"] in names or r["name"] in ("ID", "VERSION", "DATE"):
            sys.exit(f"regmap_gen: duplicate register {r['name']}")
        names.add(r["name"])
        r["offset"] = num(r["offset"])
        if r["offset"] % 4 or r["offset"] < 0x10:
            sys.exit(f"regmap_gen: {r['name']}: offset must be word aligned and >= 0x10 (after the ID block)")
        rv = r.get("reset", 0)
        try:
            r["reset"] = num(rv) & 0xFFFFFFFF
            r["reset_expr"] = None
        except ValueError:                               # an expression (may use parameters, and i in arrays)
            r["reset"] = 0
            r["reset_expr"] = str(rv)
        r.setdefault("width", 32)
        r.setdefault("count", 1)
        r["array"] = r["count"] != 1 or "max_count" in r
        if r["array"] and r["access"] == "RC":
            sys.exit(f"regmap_gen: {r['name']}: RC registers cannot be arrays")
        r["max_count"] = int(r.get("max_count", r["count"] if isinstance(r["count"], int) else 1))
        r["stride"] = int(r.get("stride", 4))
        if r["stride"] % 4 or r["stride"] < 4:
            sys.exit(f"regmap_gen: {r['name']}: stride must be a multiple of 4")
        for k in range(r["max_count"]):
            a = r["offset"] + r["stride"] * k
            if a in used:
                sys.exit(f"regmap_gen: {r['name']} overlaps {used[a]} at 0x{a:X}")
            used[a] = r["name"]
        end = max(end, r["offset"] + r["stride"] * (r["max_count"] - 1) + 4)
        occ = 0
        for f in r.get("fields", []):
            hi, lo = bits(f)
            if not 0 <= lo <= hi <= 31:
                sys.exit(f"regmap_gen: {r['name']}.{f['name']}: bad bit range")
            mask = ((1 << (hi - lo + 1)) - 1) << lo
            if occ & mask:
                sys.exit(f"regmap_gen: {r['name']}.{f['name']} overlaps another field")
            occ |= mask
            f["hi"], f["lo"], f["mask"] = hi, lo, mask
    m["map_words"] = end // 4
    aw = m.get("addr_width", max(4, (end - 1).bit_length()))
    if end > (1 << aw):
        sys.exit("regmap_gen: addr_width too small for the map")
    m["addr_width"] = aw
    return m


def wrap(text, first, cont, width=78):
    return textwrap.wrap(text, width, initial_indent=first, subsequent_indent=cont) or [first.rstrip()]


def reg_doc(m):
    """The register map as comment lines."""
    out = []
    w = 3 if m["addr_width"] > 8 else 2
    for name, off, acc, desc in ID_BLOCK:
        val = {"ID": f' "{m["id"]}"', "VERSION": "", "DATE": ""}[name]
        out += wrap(f"0x{off:0{w}X} {name:<11s} {acc:<4s}{val} {desc}", "//     ", "//" + " " * 23)
    out.append(f"//     0x{0xC:0{w}X} reserved    RO   0")
    for r in m["registers"]:
        rng = f"0x{r['offset']:0{w}X}" + (f" + {r['stride']} i" if r["array"] else "")
        cnt = f" [{r['count']}]" if r["array"] else ""
        rst = (f", reset {r['reset_expr']}" if r["reset_expr"] else f", reset 0x{r['reset']:X}") \
            if r["access"] in ("RW", "W1C", "W1S") else ""
        out += wrap(f"{rng} {r['name'] + cnt:<11s} {r['access']:<4s} {r.get('desc', '')}{rst}", "//     ",
                    "//" + " " * 23)
        for f in r.get("fields", []):
            b = f"[{f['hi']}:{f['lo']}]" if f["hi"] != f["lo"] else f"[{f['lo']}]"
            out += wrap(f"{b} {f['name']}: {f.get('desc', '')}", "//" + " " * 23, "//" + " " * 25)
    return out


def ports(m):
    p = []
    for r in m["registers"]:
        n, a, w = r["name"].lower(), r["access"], r["width"]
        cnt = r["count"]
        dw = f"({cnt})*({w})" if r["array"] else f"{w}"
        rng = f"[{dw}-1:0]" if (r["array"] or str(w) != "1") else ""
        prng = f"[{cnt}-1:0]" if r["array"] else ""
        d = r.get("desc", "")
        if a in ("RO", "CMD", "RC"):
            p.append((f"input  logic {rng}", f"{n}_i", f"{r['name']} ({a}): value read"))
        if a == "RC":
            p.append(("output logic ", f"{n}_rd_o", f"{r['name']}: one-clock pulse in the clock a read returns the value"))
        if a in ("RW", "W1C", "W1S", "WO", "CMD"):
            what = {"RW": "register value", "W1C": "status (software clears)", "W1S": "request (hardware clears)",
                    "WO": "data written", "CMD": "data written"}[a]
            p.append((f"output logic {rng}", f"{n}_o", f"{r['name']} ({a}): {what}"))
            p.append((f"output logic {prng}", f"{n}_wr_o", f"{r['name']}: one-clock pulse at every software write"))
        if a == "W1C":
            p.append((f"input  logic {rng}", f"{n}_set_i", f"{r['name']}: hardware sets bits (one-clock pulses)"))
        if a == "W1S":
            p.append((f"input  logic {rng}", f"{n}_clr_i", f"{r['name']}: hardware clears bits (one-clock pulses)"))
    return p


def gen_sv(m, stamp_v, stamp_d):
    n, aw, ck, rs = m["name"], m["addr_width"], m["clk"], m["rst_n"]
    A = f"{aw}'h"
    hdr = ["// ***************", f"// Filename: {n}.sv", "// Author: FPGA Cores 4 U"]
    hdr += wrap(f"Description: Register map of {m.get('ip', n)}: its AXI4-Lite register slave (axi4_lite_slave "
                f"front end) with every register of the block, the ID block first; the registers go to "
                f"{m.get('ip', n)}'s logic on named ports, its status comes back on input ports. "
                + m.get("desc", "") + " Generated by ip/scripts/regmap_gen.py from "
                f"{n}.json: edit the JSON and regenerate (the IP_VERSION / IP_DATE stamps are kept).",
                "// ", "//   ")
    hdr.append(f"//   Register map (ADDR_W = {aw}, byte offsets):")
    hdr += reg_doc(m)
    hdr += wrap("Access: RW read / write (byte strobes), RO read only (writes answer SLVERR), W1C hardware sets "
                "/ software writes 1 to clear (a set wins), W1S software writes 1 to set / hardware clears, WO "
                "write only (reads 0), CMD reads the hardware value, a write gives a pulse with its data. "
                "Unmapped words read 0 and ignore writes; above the map: DECERR. Clock - " + ck +
                ". Reset - synchronous active low " + rs + ". Latency - 2 clocks per write and read.",
                "//   ", "//   ")
    hdr.append(f"// Date: {datetime.date.today().isoformat()}")
    s = "\n".join(hdr) + "\n"
    par = ""
    if m["params"]:
        pl = [f"  parameter {p.get('type', 'int')} {p['name']} = {p['default']}" + ("," if i < len(m["params"]) - 1 else "") +
              (f"  // {p['desc']}" if p.get("desc") else "") for i, p in enumerate(m["params"])]
        par = " #(\n" + "\n".join(pl) + "\n)"
    s += f"module {n}{par} (\n"
    bus = [("input  logic", ck, "clock"), ("input  logic", rs, "synchronous reset, active low"),
           (f"input  logic [{aw-1}:0]", "s_axil_awaddr", "AXI4-Lite"), ("input  logic", "s_axil_awvalid", ""),
           ("output logic", "s_axil_awready", ""), ("input  logic [31:0]", "s_axil_wdata", ""),
           ("input  logic [3:0]", "s_axil_wstrb", ""), ("input  logic", "s_axil_wvalid", ""),
           ("output logic", "s_axil_wready", ""), ("output logic [1:0]", "s_axil_bresp", ""),
           ("output logic", "s_axil_bvalid", ""), ("input  logic", "s_axil_bready", ""),
           (f"input  logic [{aw-1}:0]", "s_axil_araddr", ""), ("input  logic", "s_axil_arvalid", ""),
           ("output logic", "s_axil_arready", ""), ("output logic [31:0]", "s_axil_rdata", ""),
           ("output logic [1:0]", "s_axil_rresp", ""), ("output logic", "s_axil_rvalid", ""),
           ("input  logic", "s_axil_rready", "")]
    allp = [(t, nm, c) for t, nm, c in bus] + [(t.rstrip(), nm, c) for t, nm, c in ports(m)]
    tw = max(len(t) for t, _, _ in allp) + 1
    nw = max(len(nm) for _, nm, _ in allp) + 1
    lines = []
    for i, (t, nm, c) in enumerate(allp):
        sep = "," if i < len(allp) - 1 else ""
        code = f"  {t:<{tw}}{nm}{sep}"
        lines.append(f"{code:<{tw + nw + 3}}// {c}".rstrip() if c else code)
    s += "\n".join(lines) + "\n);\n"
    s += "  // ---------------- register map\n"
    s += f'  localparam logic [31:0] IP_ID      = "{m["id"]}";\n'
    s += f"  localparam logic [31:0] IP_VERSION = {stamp_v};\n"
    s += f"  localparam logic [31:0] IP_DATE    = {stamp_d};   // mm/dd/yyyy, BCD\n"
    s += f"  localparam logic [{aw-1}:0] A_ID = {A}{0:X}, A_VERSION = {A}4, A_DATE = {A}8;\n"
    for r in m["registers"]:
        s += f"  localparam logic [{aw-1}:0] A_{r['name']} = {A}{r['offset']:X};" + \
             (f"   // + {r['stride']} i, i < {r['count']}" if r["array"] else "") + "\n"
    s += f"  localparam int MAP_WORDS = {m['map_words']};\n\n"
    s += f"""  logic             wr_en, rd_en, wr_err_q;
  logic [{aw-1}:0]       wr_addr, rd_addr, rd_addr_q;
  logic [31:0]      wr_data, rd_data;
  logic [3:0]       wr_strb;
  axi4_lite_slave #(
    .ADDR_W({aw}),
    .READ_WAIT(0),
    .MAP_WORDS(MAP_WORDS)
  ) u_axil (
    .aclk({ck}),
    .aresetn({rs}),
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .wr_en_o(wr_en),
    .wr_addr_o(wr_addr),
    .wr_data_o(wr_data),
    .wr_strb_o(wr_strb),
    .wr_err_i(wr_err_q),
    .rd_en_o(rd_en),
    .rd_addr_o(rd_addr),
    .rd_data_i(rd_data),
    .rd_valid_i(1'b1),
    .rd_err_i(1'b0)
  );
  wire [{aw-1}:0] wa = {{wr_addr[{aw-1}:2], 2'b00}};
  // byte strobes applied to the written word
  logic [31:0] wmask;
  always_comb for (int b = 0; b < 4; b++) wmask[b*8 +: 8] = {{8{{wr_strb[b]}}}};
"""
    # storage
    stored = [r for r in m["registers"] if r["access"] in ("RW", "W1C", "W1S", "WO", "CMD")]
    ro_like = [r for r in m["registers"] if r["access"] in ("RO", "RC")]
    s += "\n  // ---------------- writes\n"
    for r in stored:
        nm = r["name"].lower()
        if r["array"]:
            s += f"  logic [31:0] {nm}_q [{r['count']}];\n"
        else:
            s += f"  logic [31:0] {nm}_q;\n"
    for r in ro_like:
        if r["array"]:
            nm = r["name"].lower()
            s += (f"  logic ro_{nm};   // a write to an element of {r['name']}\n  always_comb begin\n    ro_{nm} = 1'b0;\n"
                  f"    for (int i = 0; i < {r['count']}; i++) if (wa == A_{r['name']} + {aw}'({r['stride']} * i)) ro_{nm} = 1'b1;\n"
                  f"  end\n")
    s += f"  always_ff @(posedge {ck}) begin\n    if (!{rs}) begin\n"
    for r in stored:
        nm = r["name"].lower()
        rst = ((f"32'({r['reset_expr']})" if r["reset_expr"] else f"32'h{r['reset']:X}")
               if r["access"] in ("RW", "W1C", "W1S") else "'0")
        if r["array"]:
            s += f"      for (int i = 0; i < {r['count']}; i++) {nm}_q[i] <= {rst};\n      {nm}_wr_o <= '0;\n"
        else:
            s += f"      {nm}_q <= {rst};\n      {nm}_wr_o <= 1'b0;\n"
    s += "      wr_err_q <= 1'b0;\n    end else begin\n"
    ro_names = " || ".join([f"wa == A_{x}" for x in ("ID", "VERSION", "DATE")] +
                           [(f"ro_{r['name'].lower()}" if r["array"] else f"wa == A_{r['name']}") for r in ro_like])
    s += f"      wr_err_q <= wr_en && ({ro_names});   // writes to read-only words: SLVERR\n"
    for r in stored:
        nm, a = r["name"].lower(), r["access"]
        idx = "[i]" if r["array"] else ""
        cond = (f"wr_en && wa == A_{r['name']} + {aw}'({r['stride']} * i)" if r["array"] else f"wr_en && wa == A_{r['name']}")
        upd = {"RW": f"({nm}_q{idx} & ~wmask) | (wr_data & wmask)",
               "WO": f"({nm}_q{idx} & ~wmask) | (wr_data & wmask)",
               "CMD": f"({nm}_q{idx} & ~wmask) | (wr_data & wmask)",
               "W1C": None, "W1S": None}[a]
        body = []
        loop = f"for (int i = 0; i < {r['count']}; i++) begin" if r["array"] else "begin"
        wr_pulse = f"{nm}_wr_o{idx} <= {cond};"
        W = r["width"]
        hwsl = (f"[i*({W}) +: {W}]" if r["array"] else "")
        if a in ("RW", "WO", "CMD"):
            body = [wr_pulse, f"if ({cond}) {nm}_q{idx} <= {upd};"]
        elif a == "W1C":
            body = [wr_pulse, f"{nm}_q{idx} <= (({cond}) ? {nm}_q{idx} & ~(wr_data & wmask) : {nm}_q{idx})"
                              f" | 32'({nm}_set_i{hwsl});   // a set wins over a clear"]
        elif a == "W1S":
            body = [wr_pulse, f"{nm}_q{idx} <= ({nm}_q{idx} & ~32'({nm}_clr_i{hwsl}))"
                              f" | (({cond}) ? wr_data & wmask : 32'd0);   // a set wins over a clear"]
        s += f"      {loop}\n" + "".join(f"        {b}\n" for b in body) + "      end\n"
    s += "    end\n  end\n"
    for r in stored:
        nm, W = r["name"].lower(), r["width"]
        if r["array"]:
            s += f"  always_comb for (int i = 0; i < {r['count']}; i++) {nm}_o[i*({W}) +: {W}] = {nm}_q[i][{W}-1:0];\n"
        else:
            s += f"  assign {nm}_o = {nm}_q[{W}-1:0];\n"
    # reads
    s += f"""
  // ---------------- reads: the word addressed in the clock before
  always_ff @(posedge {ck}) if (rd_en) rd_addr_q <= {{rd_addr[{aw-1}:2], 2'b00}};
  always_comb begin
    rd_data = '0;
    case (rd_addr_q)
      A_ID:      rd_data = IP_ID;
      A_VERSION: rd_data = IP_VERSION;
      A_DATE:    rd_data = IP_DATE;
"""
    arrays = []
    for r in m["registers"]:
        nm, a, W = r["name"].lower(), r["access"], r["width"]
        if r["array"]:
            arrays.append(r)
            continue
        if a == "WO":
            continue
        src = f"{nm}_i" if a in ("RO", "CMD", "RC") else f"{nm}_q"
        s += f"      A_{r['name']}: rd_data = 32'({src});\n" if a in ("RO", "CMD", "RC") else f"      A_{r['name']}: rd_data = {src};\n"
    s += "      default: begin\n"
    for r in arrays:
        nm, a, W = r["name"].lower(), r["access"], r["width"]
        if a == "WO":
            continue
        src = f"32'({nm}_i[i*({W}) +: {W}])" if a in ("RO", "CMD") else f"{nm}_q[i]"
        s += (f"        for (int i = 0; i < {r['count']}; i++)\n"
              f"          if (rd_addr_q == A_{r['name']} + {aw}'({r['stride']} * i)) rd_data = {src};\n")
    s += "      end\n    endcase\n  end\n"
    rc = [r for r in m["registers"] if r["access"] == "RC"]
    if rc:
        s += (f"\n  // ---------------- read pulses (RC): the clock the value is returned\n  logic rd_take_q;\n"
              f"  always_ff @(posedge {ck}) begin\n    if (!{rs}) rd_take_q <= 1'b0;\n    else rd_take_q <= rd_en;\n  end\n")
        for r in rc:
            s += f"  assign {r['name'].lower()}_rd_o = rd_take_q && rd_addr_q == A_{r['name']};\n"
    s += "endmodule\n"
    return s


def gen_h(m):
    n = m["name"].upper()
    s = (f"// ***************\n// Filename: {m['name']}.h\n// Author: FPGA Cores 4 U\n// Description: C header of "
         f"the {m.get('ip', m['name'])} register map (generated by regmap_gen.py): byte offsets, reset values,\n"
         f"//   field shifts and masks.\n// Date: {datetime.date.today().isoformat()}\n")
    s += f"#ifndef {n}_H\n#define {n}_H\n"
    s += f"#define {n}_ID_OFFSET 0x00u\n#define {n}_VERSION_OFFSET 0x04u\n#define {n}_DATE_OFFSET 0x08u\n"
    s += f"#define {n}_ID_VALUE 0x{int.from_bytes(m['id'].encode(), 'big'):08X}u   /* \"{m['id']}\" */\n"
    for r in m["registers"]:
        rn = r["name"].upper()
        s += f"#define {n}_{rn}_OFFSET 0x{r['offset']:02X}u   /* {r['access']}{(' array, stride ' + str(r['stride'])) if r['array'] else ''} */\n"
        if r["array"]:
            s += f"#define {n}_{rn}_STRIDE {r['stride']}u\n"
        if not r["reset_expr"]:
            s += f"#define {n}_{rn}_RESET 0x{r['reset']:08X}u\n"
        for f in r.get("fields", []):
            fn = f["name"].upper()
            s += f"#define {n}_{rn}_{fn}_SHIFT {f['lo']}u\n#define {n}_{rn}_{fn}_MASK 0x{f['mask']:08X}u\n"
    return s + f"#endif /* {n}_H */\n"


def gen_md(m):
    s = f"# {m.get('ip', m['name'])} register map\n\n{m.get('desc', '')}\n\n"
    s += "| Offset | Name | Access | Reset | Description |\n|---|---|---|---|---|\n"
    s += f"| 0x00 | ID | RO | \"{m['id']}\" | {ID_BLOCK[0][3]} |\n| 0x04 | VERSION | RO | - | {ID_BLOCK[1][3]} |\n"
    s += f"| 0x08 | DATE | RO | - | {ID_BLOCK[2][3]} |\n| 0x0C | reserved | RO | 0 | |\n"
    for r in m["registers"]:
        off = f"0x{r['offset']:02X}" + (f" + {r['stride']} i (i < {r['count']})" if r["array"] else "")
        rst = f"`{r['reset_expr']}`" if r["reset_expr"] else f"0x{r['reset']:08X}"
        s += f"| {off} | {r['name']} | {r['access']} | {rst} | {r.get('desc', '')} |\n"
    for r in m["registers"]:
        if r.get("fields"):
            s += f"\n### {r['name']} (0x{r['offset']:02X})\n\n| Bits | Field | Description |\n|---|---|---|\n"
            for f in r["fields"]:
                b = f"{f['hi']}:{f['lo']}" if f["hi"] != f["lo"] else f"{f['lo']}"
                s += f"| {b} | {f['name']} | {f.get('desc', '')} |\n"
    return s


def gen_xml(m, stamp_v, stamp_d):
    """IP-XACT 1685-2014 component: one memory map, one address block, the ID block and every register
    (arrays as registers with dim / stride), fields with their access."""
    from xml.sax.saxutils import escape as esc
    acc = {"RW": "read-write", "RO": "read-only", "W1C": "read-write", "W1S": "read-write", "WO": "write-only",
           "CMD": "read-write", "RC": "read-only"}
    mod = {"W1C": "oneToClear", "W1S": "oneToSet"}
    ver = stamp_v.strip('"')
    span = m["map_words"] * 4
    x = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<!-- {m["name"]}.xml: IP-XACT register map of {m.get("ip", m["name"])}, generated by ip/scripts/regmap_gen.py from {m["name"]}.json -->',
         '<ipxact:component xmlns:ipxact="http://www.accellera.org/XMLSchema/IPXACT/1685-2014"',
         '                  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
         '                  xsi:schemaLocation="http://www.accellera.org/XMLSchema/IPXACT/1685-2014 '
         'http://www.accellera.org/XMLSchema/IPXACT/1685-2014/index.xsd">',
         '  <ipxact:vendor>fpgacores4u</ipxact:vendor>',
         '  <ipxact:library>digital_ip</ipxact:library>',
         f'  <ipxact:name>{esc(m.get("ip", m["name"]))}</ipxact:name>',
         f'  <ipxact:version>{esc(ver)}</ipxact:version>',
         '  <ipxact:memoryMaps>',
         '    <ipxact:memoryMap>',
         f'      <ipxact:name>{esc(m["name"])}</ipxact:name>',
         f'      <ipxact:description>{esc(m.get("desc", ""))} ID "{esc(m["id"])}", date {stamp_d}.</ipxact:description>',
         '      <ipxact:addressBlock>',
         '        <ipxact:name>regs</ipxact:name>',
         '        <ipxact:baseAddress>0x0</ipxact:baseAddress>',
         f'        <ipxact:range>0x{span:X}</ipxact:range>',
         '        <ipxact:width>32</ipxact:width>',
         '        <ipxact:usage>register</ipxact:usage>']

    def reg(name, off, access, desc, reset, fields, dim=None, stride=None):
        out = ['        <ipxact:register>', f'          <ipxact:name>{esc(name)}</ipxact:name>']
        if desc:
            out.append(f'          <ipxact:description>{esc(desc)}</ipxact:description>')
        if dim:
            out.append(f'          <ipxact:dim>{esc(str(dim))}</ipxact:dim>')
        out += [f'          <ipxact:addressOffset>0x{off:X}</ipxact:addressOffset>',
                '          <ipxact:size>32</ipxact:size>']
        flist = fields or [{"name": name, "lo": 0, "hi": 31, "desc": ""}]
        for f in flist:
            w = f["hi"] - f["lo"] + 1
            out += ['          <ipxact:field>', f'            <ipxact:name>{esc(f["name"])}</ipxact:name>']
            if f.get("desc"):
                out.append(f'            <ipxact:description>{esc(f["desc"])}</ipxact:description>')
            out += [f'            <ipxact:bitOffset>{f["lo"]}</ipxact:bitOffset>']
            if reset is not None:
                rv = (reset >> f["lo"]) & ((1 << w) - 1)
                out += ['            <ipxact:resets>', '              <ipxact:reset>',
                        f'                <ipxact:value>0x{rv:X}</ipxact:value>', '              </ipxact:reset>',
                        '            </ipxact:resets>']
            out += [f'            <ipxact:bitWidth>{w}</ipxact:bitWidth>', f'            <ipxact:access>{acc[access]}</ipxact:access>']
            if access in mod:
                out.append(f'            <ipxact:modifiedWriteValue>{mod[access]}</ipxact:modifiedWriteValue>')
            if access == "RC":
                out.append('            <ipxact:readAction>modify</ipxact:readAction>')
            out.append('          </ipxact:field>')
        if stride:                                       # schema order: after the fields
            out.append(f'          <ipxact:vendorExtensions><stride>{stride}</stride></ipxact:vendorExtensions>')
        out.append('        </ipxact:register>')
        return out

    idval = int.from_bytes(m["id"].encode(), "big")
    verval = int.from_bytes(ver.encode(), "big")
    dateval = int(stamp_d.split("'h")[1], 16) if "'h" in stamp_d else 0
    x += reg("ID", 0x0, "RO", ID_BLOCK[0][3], idval, None)
    x += reg("VERSION", 0x4, "RO", ID_BLOCK[1][3], verval, None)
    x += reg("DATE", 0x8, "RO", ID_BLOCK[2][3], dateval, None)
    for r in m["registers"]:
        rst = None if r["reset_expr"] or r["access"] in ("RO", "WO", "CMD", "RC") else r["reset"]
        desc = r.get("desc", "") + (f" (reset {r['reset_expr']})" if r["reset_expr"] else "")
        x += reg(r["name"], r["offset"], r["access"], desc, rst, r.get("fields"),
                 dim=(r["count"] if r["array"] else None), stride=(r["stride"] if r["array"] else None))
    x += ['      </ipxact:addressBlock>', '      <ipxact:addressUnitBits>8</ipxact:addressUnitBits>',
          '    </ipxact:memoryMap>', '  </ipxact:memoryMaps>', '</ipxact:component>']
    return "\n".join(x) + "\n"


# ---------------------------------------------------------------- wrapper (<ip>_top.sv)

def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def split_top(text, sep=","):
    """Split at sep outside (), [], {}."""
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def parse_module(path, name):
    """(parameters [(type, name, default)], ports [(dir, type_and_range, name)]) of module name in path."""
    t = strip_comments(open(path).read())
    m = re.search(rf"\bmodule\s+{re.escape(name)}\b", t)
    if not m:
        sys.exit(f"regmap_gen: module {name} not found in {path}")
    i = m.end()
    params = []
    rest = t[i:].lstrip()
    if rest.startswith("#"):
        j = t.index("(", i)
        depth, k = 0, j
        while True:
            if t[k] == "(":
                depth += 1
            elif t[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        for item in split_top(t[j + 1:k]):
            item = " ".join(item.split())
            if not item:
                continue
            mm = re.match(r"(?:parameter\s+)?(.*?)\b(\w+)\s*=\s*(.+)$", item)
            params.append(((mm.group(1).strip() or "int"), mm.group(2), mm.group(3).strip()))
        i = k + 1
    j = t.index("(", i)
    depth, k = 0, j
    while True:
        if t[k] == "(":
            depth += 1
        elif t[k] == ")":
            depth -= 1
            if depth == 0:
                break
        k += 1
    ports = []
    last = ("input", "logic")
    for item in split_top(t[j + 1:k]):
        item = " ".join(item.split())
        if not item or item.startswith("`"):
            continue
        mm = re.match(r"(input|output|inout)\s+(.*?)\s*(\w+)$", item)
        if mm:
            d, ty, n = mm.group(1), mm.group(2), mm.group(3)
            last = (d, ty)
        else:
            d, ty, n = last[0], last[1], item.strip()
        ports.append((d, ty or "logic", n))
    return params, ports


def gen_top(m, core_path):
    ip, core, top = m.get("ip", m["name"]), m["core"], m["top"]
    params, ports = parse_module(core_path, core)
    pnames = [p[1] for p in params]
    cports = {n: (d, ty) for d, ty, n in ports}
    regs = m["registers"]
    conn, wires, used = [], [], set()

    def want(port, direction, required):
        """The core port for a register-block port, or None."""
        if port in cports:
            if cports[port][0] != direction:
                sys.exit(f"regmap_gen: {core}.{port} must be an {direction}")
            used.add(port)
            return port
        if required:
            sys.exit(f"regmap_gen: {core} has no {direction} port {port} for register {port.split('_', 1)[1].upper()}")
        return None

    for r in regs:
        n, a = r["name"].lower(), r["access"]
        if a in ("RW", "W1C", "W1S", "WO", "CMD"):
            c = want(f"cfg_{n}", "input", False)
            conn.append((f"{n}_o", c or ""))
            c = want(f"cfg_{n}_wr", "input", False)
            conn.append((f"{n}_wr_o", c or ""))
        if a in ("RO", "CMD", "RC"):
            conn.append((f"{n}_i", want(f"sts_{n}", "output", True)))
        if a == "RC":
            c = want(f"cfg_{n}_rd", "input", False)
            conn.append((f"{n}_rd_o", c or ""))
        if a == "W1C":
            c = want(f"sts_{n}_set", "output", False)
            conn.append((f"{n}_set_i", c or "'0"))
        if a == "W1S":
            c = want(f"sts_{n}_clr", "output", False)
            conn.append((f"{n}_clr_i", c or "'0"))
    extra = [n for n in cports if (n.startswith("cfg_") or n.startswith("sts_")) and n not in used]
    if extra:
        sys.exit(f"regmap_gen: {core} ports without a register: {', '.join(extra)}")
    for n in sorted(used, key=lambda x: [p[2] for p in ports].index(x)):
        d, ty = cports[n]
        wires.append(f"  {ty} {n};".replace("  logic  ", "  logic "))
    ck, rs = m["clk"], m["rst_n"]
    if ck not in cports or rs not in cports:
        sys.exit(f"regmap_gen: {core} must have the ports {ck} and {rs}")
    # wrapper ports: the core's, the AXI4-Lite bus after the reset
    aw = m["addr_width"]
    axi = [("input", f"logic [{aw-1}:0]", "s_axil_awaddr"), ("input", "logic", "s_axil_awvalid"),
           ("output", "logic", "s_axil_awready"), ("input", "logic [31:0]", "s_axil_wdata"),
           ("input", "logic [3:0]", "s_axil_wstrb"), ("input", "logic", "s_axil_wvalid"),
           ("output", "logic", "s_axil_wready"), ("output", "logic [1:0]", "s_axil_bresp"),
           ("output", "logic", "s_axil_bvalid"), ("input", "logic", "s_axil_bready"),
           ("input", f"logic [{aw-1}:0]", "s_axil_araddr"), ("input", "logic", "s_axil_arvalid"),
           ("output", "logic", "s_axil_arready"), ("output", "logic [31:0]", "s_axil_rdata"),
           ("output", "logic [1:0]", "s_axil_rresp"), ("output", "logic", "s_axil_rvalid"),
           ("input", "logic", "s_axil_rready")]
    tports = []
    for d, ty, n in ports:
        if n in used:
            continue
        tports.append((d, ty, n))
        if n == rs:
            tports += axi
    tw = max(len(f"{d:<6} {ty}") for d, ty, _ in tports) + 1
    hdr = ["// ***************", f"// Filename: {top}.sv", "// Author: FPGA Cores 4 U"]
    hdr += wrap(f"Description: {ip} with its AXI4-Lite register interface, the block designs and testbenches "
                f"instantiate: the register map {m['name']} (u_regs, src/include/{m['name']}.sv, ID \"{m['id']}\", "
                f"VERSION and DATE at 0x00-0x08, the registers from 0x10) and the logic {core} (u_core, src/{core}.sv), "
                f"joined by their register ports (cfg_* to the logic, sts_* back). Generated by ip/scripts/regmap_gen.py "
                f"from {m['name']}.json and the ports of {core}: regenerate after changing either. Clock - {ck}. "
                f"Reset - synchronous active low {rs}.", "// ", "//   ")
    hdr.append(f"// Date: {datetime.date.today().isoformat()}")
    s = "\n".join(hdr) + "\n"
    allp = params + [(p.get("type", "int"), p["name"], str(p["default"])) for p in m.get("top_params", [])]
    if allp:
        pl = [f"  parameter {ty} {n} = {dv}" + ("," if i < len(allp) - 1 else "") for i, (ty, n, dv) in enumerate(allp)]
        s += f"module {top} #(\n" + "\n".join(pl) + "\n) (\n"
    else:
        s += f"module {top} (\n"
    s += "\n".join(f"  {f'{d:<6} {ty}':<{tw}}{n}" + ("," if i < len(tports) - 1 else "")
                    for i, (d, ty, n) in enumerate(tports)) + "\n);\n"
    for lp in m.get("top_localparams", []):
        s += f"  {lp}\n"
    s += "  // register ports between the register map and the logic\n" + "\n".join(wires) + "\n\n"
    rp = []
    rpar = m.get("regs_params", {})
    for p in m["params"]:
        tops = pnames + [q["name"] for q in m.get("top_params", [])]
        v = rpar.get(p["name"], p["name"] if p["name"] in tops or any(p["name"] in lp for lp in m.get("top_localparams", [])) else None)
        if v is not None:
            rp.append((p["name"], v))
    s += f"  {m['name']}" + (" #(\n" + ",\n".join(f"    .{k}({v})" for k, v in rp) + "\n  )" if rp else "") + " u_regs (\n"
    rc = [f".{ck}", f".{rs}"] + [f".{n}" for _, _, n in axi] + [f".{a}({b})" for a, b in conn]
    s += ",\n".join(f"    {c}" for c in rc) + "\n  );\n"
    s += f"  {core}" + (" #(\n" + ",\n".join(f"    .{n}({n})" for _, n, _ in params) + "\n  )" if params else "") + " u_core (\n"
    s += ",\n".join(f"    .{n}" for _, _, n in ports) + "\n  );\nendmodule\n"
    return s


def stamps_of(path, m):
    """IP_VERSION / IP_DATE already in the generated file (kept), else the JSON version and today."""
    t = datetime.date.today()
    v, d = f'"{m["version"]}"', f"32'h{t.month:02d}{t.day:02d}{t.year:04d}"
    if os.path.isfile(path):
        for k, val in STAMP_RE.findall(open(path).read()):
            if k == "VERSION":
                v = val.strip()
            else:
                d = val.strip()
    return v, d


def strip(s):
    s = STAMP_RE.sub("<stamp>", s)
    return re.sub(r"^// Date: .*$", "// Date:", s, flags=re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("outdir", nargs="?")
    ap.add_argument("--doc")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    m = load(a.json)
    m.setdefault("core", m.get("ip", m["name"]))
    m.setdefault("top", f"{m.get('ip', m['name'])}_top")
    out = a.outdir or os.path.dirname(os.path.abspath(a.json))
    doc = a.doc
    if not doc:                                          # the IP's docs/: up from src/include/
        doc = out
        d = os.path.abspath(out)
        for _ in range(3):
            d = os.path.dirname(d)
            if os.path.isdir(os.path.join(d, "docs")):
                doc = os.path.join(d, "docs")
                break
    sv_path = os.path.join(out, f"{m['name']}.sv")
    v, d = stamps_of(sv_path, m)
    sv = gen_sv(m, v, d)
    if a.check:
        cur = open(sv_path).read() if os.path.isfile(sv_path) else ""
        if strip(cur) != strip(sv):
            print(f"regmap_gen: {sv_path} is out of date (regenerate from {a.json})")
            sys.exit(1)
        return
    os.makedirs(out, exist_ok=True)
    os.makedirs(doc, exist_ok=True)
    open(sv_path, "w").write(sv)
    open(os.path.join(out, f"{m['name']}.h"), "w").write(gen_h(m))
    open(os.path.join(doc, f"{m['name']}.md"), "w").write(gen_md(m))
    open(os.path.join(out, f"{m['name']}.xml"), "w").write(gen_xml(m, v, d))
    src_dir = os.path.dirname(os.path.abspath(out)) if os.path.basename(os.path.abspath(out)) == "include" else out
    core_path = (os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(a.json)), m["core_file"]))
                 if m.get("core_file") else os.path.join(src_dir, f"{m['core']}.sv"))
    if m["top"] and os.path.isfile(core_path):
        src_core = open(core_path).read()
        if re.search(r"\b(cfg|sts)_\w+", src_core):         # the core uses the register-port convention
            open(os.path.join(src_dir, f"{m['top']}.sv"), "w").write(gen_top(m, core_path))
            print(f"regmap_gen: wrote {m['top']}.sv (wrapper of {m['core']}) in {os.path.relpath(src_dir)}")
    print(f"regmap_gen: wrote {m['name']}.sv / .h / .xml in {os.path.relpath(out)}, {m['name']}.md in {os.path.relpath(doc)}")


if __name__ == "__main__":
    main()
