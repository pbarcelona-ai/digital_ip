#!/usr/bin/env python3
# ***************
# Filename: make_block_diagrams.py
# Author: Paul Barcelona
# Description: Generates the block diagram of every image IP as a Graphviz
#   source (<ip>/doc/block_diagram.dot) and renders it to SVG
#   (<ip>/doc/block_diagram.svg) with "dot". The stage names and counts come
#   from the RTL (see the pipeline comments in <ip>/src/<ip>.sv), so when a
#   datapath changes, update the matching entry below and re-run.
#
#   Usage:  tools/docs/make_block_diagrams.py            write .dot and .svg
#           tools/docs/make_block_diagrams.py --dot-only write only the .dot
#           tools/docs/make_block_diagrams.py --check    exit 1 if a committed .dot is
#                                                        out of date, or if the RTL no longer
#                                                        matches what a diagram states
#           tools/docs/make_block_diagrams.py scaler_bicubic sharpen_cas
#   Needs Python 3 (standard library only) and Graphviz "dot" (not for
#   --dot-only / --check).
#
#   Conventions: blue = interface, green = control, amber = memory or table,
#   grey = datapath stage, red row = stage built around DSP48 multipliers.
#   Solid arrows carry data, dashed arrows carry configuration or sequencing.
# Date: 2026-09-28

import argparse
import html
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

KIND = {  # background, header, border
    "port": ("#dbeafe", "#bfdbfe", "#2563eb"),
    "ctl":  ("#dcfce7", "#bbf7d0", "#16a34a"),
    "mem":  ("#fef3c7", "#fde68a", "#d97706"),
    "dp":   ("#ffffff", "#e5e7eb", "#4b5563"),
    "note": ("#fffbeb", "#fef3c7", "#a16207"),
}
DSP = "#fecaca"
FONT = "Helvetica"


def esc(s):
    return html.escape(s, quote=False)


def lines(s):
    """text with \n -> left-aligned line breaks (no trailing break)"""
    return '<BR ALIGN="LEFT"/>'.join(esc(x) for x in s.split("\n"))


def row(tag, text, dsp=False):
    return (tag, text, dsp)


def sec(title):
    """section header row inside a block"""
    return ("§", title, None)


class Dot:
    """tiny helper collecting DOT statements"""

    def __init__(self, name):
        self.name = name
        self.body = []
        self.ind = 1

    def add(self, s):
        for ln in s.split("\n"):
            self.body.append("  " * self.ind + ln if ln.strip() else "")

    def open_cluster(self, cid, label, fill="#f9fafb", color="#9ca3af", bold=False):
        self.add(f'subgraph cluster_{cid} {{')
        self.ind += 1
        self.add(f'label=<<B>{esc(label)}</B>>; labeljust=l; style="rounded,filled"; fillcolor="{fill}"; '
                 f'color="{color}"; penwidth={2 if bold else 1}; fontname="{FONT}"; fontsize=12; margin=12;')

    def close(self):
        self.ind -= 1
        self.add("}")

    def port(self, nid, text):
        self.add(f'{nid} [shape=box, style="rounded,filled", fillcolor="{KIND["port"][0]}", '
                 f'color="{KIND["port"][2]}", penwidth=1.5, label={self._q(text)}];')

    @staticmethod
    def _q(s):
        return '"' + s.replace('"', '\\"').replace("\n", "\\n") + '"'

    def block(self, nid, title, rows, kind="dp", sub=None):
        bg, hd, bd = KIND[kind]
        t = [f'{nid} [label=<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3" '
             f'BGCOLOR="{bg}" COLOR="{bd}" STYLE="rounded">']
        t.append(f'  <TR><TD BGCOLOR="{hd}" STYLE="rounded"><B>{esc(title)}</B></TD></TR>')
        if sub:
            t.append(f'  <TR><TD><FONT POINT-SIZE="9" COLOR="#4b5563"><I>{esc(sub)}</I></FONT></TD></TR>')
        for r in rows:
            if isinstance(r, str):
                t.append(f'  <TR><TD ALIGN="LEFT" BALIGN="LEFT">{lines(r)}<BR ALIGN="LEFT"/></TD></TR>')
                continue
            tag, text, dsp = r
            if tag == "§":
                t.append(f'  <TR><TD BGCOLOR="{hd}" ALIGN="LEFT"><FONT POINT-SIZE="10"><B>{esc(text)}</B></FONT></TD></TR>')
                continue
            bgc = f' BGCOLOR="{DSP}"' if dsp else ""
            mark = ' <FONT POINT-SIZE="8"><B>[DSP48]</B></FONT>' if dsp else ""
            head = f"<B>{esc(tag)}</B>&nbsp;&nbsp;" if tag else ""
            t.append(f'  <TR><TD ALIGN="LEFT" BALIGN="LEFT"{bgc}>{head}{lines(text)}{mark}<BR ALIGN="LEFT"/></TD></TR>')
        t.append("</TABLE>>];")
        self.add("\n".join(t))

    def same(self, *ids):
        self.add("{ rank=same; " + "; ".join(ids) + "; }")

    def edge(self, a, b, label="", style="solid", color="#374151", extra=""):
        lab = f', label={self._q(label)}' if label else ""
        st = "" if style == "solid" else f', style={style}'
        pw = ', penwidth=1.6' if style == "solid" else ""
        self.add(f'{a} -> {b} [color="{color}"{st}{pw}{lab}{extra}];')

    def render(self, title, subtitle, legend=True):
        head = [f'digraph "{self.name}" {{',
                f'  graph [rankdir=LR, fontname="{FONT}", nodesep=0.35, ranksep=0.6, pad=0.25, '
                f'newrank=true, splines=true, bgcolor="white", labelloc=t, labeljust=l];',
                f'  node  [shape=plain, fontname="{FONT}", fontsize=11];',
                f'  edge  [fontname="{FONT}", fontsize=9, arrowsize=0.75];']
        lab = ['<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="2">',
               f'<TR><TD ALIGN="LEFT"><FONT POINT-SIZE="18"><B>{esc(title)}</B></FONT></TD></TR>',
               f'<TR><TD ALIGN="LEFT"><FONT POINT-SIZE="11" COLOR="#374151">{lines(subtitle)}<BR ALIGN="LEFT"/></FONT></TD></TR>']
        if legend:
            cells = "".join(
                f'<TD BGCOLOR="{bg}" COLOR="{bd}" BORDER="1" STYLE="rounded"><FONT POINT-SIZE="9"> {txt} </FONT></TD><TD> </TD>'
                for bg, bd, txt in (
                    (KIND["port"][0], KIND["port"][2], "interface"),
                    (KIND["ctl"][0], KIND["ctl"][2], "control"),
                    (KIND["mem"][0], KIND["mem"][2], "memory / table"),
                    (KIND["dp"][1], KIND["dp"][2], "datapath stage"),
                    (DSP, KIND["dp"][2], "DSP48 multipliers")))
            lab.append(f'<TR><TD ALIGN="LEFT"><TABLE BORDER="0" CELLSPACING="0" CELLPADDING="2"><TR>{cells}</TR></TABLE></TD></TR>')
        lab.append("</TABLE>")
        head.append('  label=<' + "".join(lab) + '>;')
        return "\n".join(head + self.body + ["}"]) + "\n"


# -----------------------------------------------------------------------------
# shared building blocks
# -----------------------------------------------------------------------------
def add_regbus_ctrl(d, ip_regs_note=None):
    d.block("regbus", "axil_regbus", [
        "AXI4-Lite slave -> one-cycle register bus",
        "AW and W in any order, OKAY responses",
    ], "ctl")
    d.block("ctrl", "scaler_ctrl", [
        "common registers 0x000-0x02F: CTRL, STATUS,\nIN/OUT_SIZE, STEP_X/Y, OFFS_X/Y, FRAME_CNT,\nIP_ID, CAPS, MAX_SIZE",
        "addresses >= 0x040 -> IP registers (ext bus)",
        "capture FSM: SOF / EOL checks, writes the\nframe store, flags SOF_ERR / EOL_ERR",
        "sequencing: frame | ping-pong | line buffer",
    ], "ctl")


def add_dda(d):
    d.block("dda", "scaler_dda", [
        "src_x = OFFS_X + ox * STEP_X\nsrc_y = OFFS_Y + oy * STEP_Y   (signed 16.16)",
        "exact accumulation, SOF / EOL / EOF flags",
        "stalls with the pipeline (adv), hold for LINE_BUF",
    ], "ctl")


def fb_rows(taps, extra=None):
    b = 1
    while b < taps:
        b *= 2
    r = [
        f"{b} x {b} RAM banks (B = {b}): a {taps}x{taps} window every clock" if taps > 1 else
        "1 x 1: one RAM bank, one pixel every clock",
        "clamp-to-edge addressing",
        row("A", "bank addresses, tap selects (registers)"),
        row("B", "RAM read data (registers)"),
        "tap multiplexer -> window",
        "modes: frame buffer | PINGPONG (2 frames) |\nLINE_BUF (ring of lines)",
    ]
    return r + (extra or [])


def add_fb(d, taps, sub=None):
    d.block("fb", "banked_framebuf", fb_rows(taps), "mem", sub=sub or f"TAPS = {taps}")


def base_edges(d, prep="prep", last="last"):
    d.edge("s_axil", "regbus", "AXI4-Lite")
    d.edge("regbus", "ctrl", "register bus")
    d.edge("s_axis", "ctrl", "AXI4-Stream\nvideo in")
    d.edge("ctrl", "dda", "sizes, STEP, OFFS,\ngen_start", style="dashed", color="#6b7280")
    d.edge("ctrl", "fb", "write port\n(x, y, data, buffer)")
    d.edge("dda", prep, "source x, y\n+ SOF/EOL/EOF")
    d.edge(prep, "fb", "window origin,\nphases")
    d.edge(last, "m_axis", "AXI4-Stream\nvideo out")
    d.edge(last, "ctrl", "gen_done\n(last pixel accepted)", style="dashed", color="#6b7280",
           extra=", constraint=false")


# -----------------------------------------------------------------------------
# frame-store scalers: nearest, bilinear, edge-directed, polyphase family
# -----------------------------------------------------------------------------
def scaler_diagram(cfg):
    d = Dot(cfg["name"])
    d.port("s_axil", "s_axil\nAXI4-Lite\n(control)")
    d.port("s_axis", "s_axis\nAXI4-Stream video in\n(tuser = SOF, tlast = EOL)")
    d.port("m_axis", "m_axis\nAXI4-Stream video out\n(tuser = SOF, tlast = EOL)")
    wrap = cfg.get("wrapper")
    d.open_cluster("top", cfg["name"] + (" (wrapper)" if wrap else ""), bold=True)
    if wrap:
        d.open_cluster("core", wrap, fill="#f3f4f6")
    add_regbus_ctrl(d)
    add_dda(d)
    d.block("prep", cfg["prep_title"], cfg["prep_rows"], "dp", sub="combinational")
    add_fb(d, cfg["taps"], sub=cfg.get("fb_sub"))
    rows = []
    for title, prow in cfg["phases"]:
        rows.append(sec(title))
        rows.extend(prow)
    d.block("dp", "Pipelined datapath", rows, "dp", sub=cfg.get("dp_sub"))
    if cfg.get("tables"):
        d.block("tables", cfg["tables"][0], cfg["tables"][1], "mem")
    if cfg.get("ipregs"):
        d.block("ipregs", cfg["ipregs"][0], cfg["ipregs"][1], "ctl")
    if wrap:
        d.close()
    d.close()
    d.same("s_axil", "s_axis")
    d.same("regbus", "ctrl")
    d.same("dda", "prep")
    side = [n for n in ("tables", "ipregs") if cfg.get(n)]
    d.same("dp", *side)
    d.edge("s_axil", "regbus", "AXI4-Lite")
    d.edge("s_axis", "ctrl", "AXI4-Stream\nvideo in")
    d.edge("regbus", "ctrl", "register bus")
    d.edge("ctrl", "dda", "sizes, STEP,\nOFFS, start", style="dashed", color="#6b7280")
    d.edge("dda", "prep", "source x, y\n+ flags")
    d.edge("ctrl", "fb", "write port\n(x, y, data, buffer)")
    d.edge("prep", "fb", "window origin,\nphases")
    d.edge("fb", "dp", "window")
    d.edge("dp", "m_axis", "AXI4-Stream\nvideo out")
    d.edge("dp", "ctrl", "gen_done", style="dashed", color="#6b7280", extra=", constraint=false")
    if cfg.get("tables"):
        d.edge("ctrl", "tables", "ext bus (write)", style="dashed", color="#6b7280", extra=", constraint=false")
        d.edge("tables", "dp", cfg.get("tables_label", ""), style="dashed", color="#d97706")
    if cfg.get("ipregs"):
        d.edge("ctrl", "ipregs", "ext bus", style="dashed", color="#6b7280", extra=", constraint=false")
        d.edge("ipregs", "dp", "", style="dashed", color="#16a34a")
    return d.render(cfg["title"], cfg["subtitle"])


PIXEL = "pixel = CHANNELS x COMP_W bits (default 3 x 8), component 0 in the LSBs"

NEAREST = dict(
    name="scaler_nearest", title="scaler_nearest - nearest-neighbour scaler",
    subtitle="out(ox, oy) = in(round(src_x), round(src_y)) - no arithmetic on the pixels\n"
             "1 output pixel per clock - latency: one input frame (default, PINGPONG) or a few lines (LINE_BUF)\n" + PIXEL,
    prep_title="round to nearest",
    prep_rows=["ix = floor(src_x + 0.5)", "iy = floor(src_y + 0.5)", "(clamping happens in the frame store)"],
    taps=1, dp_sub="2 stages (A B) + output register",
    phases=[("Output", [
        row("A, B", "frame store read (2-cycle latency)"),
        row("out", "the 1x1 window is the output pixel:\nregistered onto m_axis"),
        "no multipliers, no coefficients, no IP registers",
    ])],
)

BILINEAR = dict(
    name="scaler_bilinear", title="scaler_bilinear - bilinear (2x2) scaler",
    subtitle="weights computed in hardware from the sub-pixel phase (PHASE_BITS = 8), no coefficient tables\n"
             "1 output pixel per clock - 6 pipeline stages (A B W M1 S1 M2) + output register\n" + PIXEL,
    prep_title="quantise to the phase grid",
    prep_rows=["s_r = s + 2^(15 - PB)", "i = s_r >> 16  (window origin)", "fx, fy = s_r[15 : 16-PB]  (phases)"],
    taps=2, dp_sub="6 stages (A B W M1 S1 M2) + output register",
    phases=[
        ("Window", [row("W", "window register: p00 p01 / p10 p11\nphases fx, fy travel with the data")]),
        ("Horizontal pass", [
            row("M1", "p00*(ONE-fx)  p01*fx\np10*(ONE-fx)  p11*fx", True),
            row("S1", "top = p00a + p01b\nbot = p10a + p11b"),
        ]),
        ("Vertical pass", [row("M2", "top*(ONE-fy)   bot*fy", True)]),
        ("Output", [
            row("out", "(pv0 + pv1 + ONE^2/2) >> 2*PB\nconvex weights: no clamping needed"),
            "-> m_axis register",
        ]),
    ],
)

EDGE = dict(
    name="scaler_edge_directed", title="scaler_edge_directed - edge-directed (triangulated) scaler",
    subtitle="splits the 2x2 cell along the stronger diagonal so interpolation never crosses an edge\n"
             "1 output pixel per clock - 8 pipeline stages (A B W D C G M S) + output register\n" + PIXEL,
    prep_title="quantise to the phase grid",
    prep_rows=["s_r = s + 2^(15 - PB)", "i = s_r >> 16  (window origin)", "fx, fy = s_r[15 : 16-PB]  (phases)"],
    taps=2, dp_sub="8 stages (A B W D C G M S) + output register",
    phases=[
        ("Window", [row("W", "window p00 p01 / p10 p11\nsample position x, y (phases)")]),
        ("Edge decision", [
            row("D", "d1 = sum_c |p00 - p11|    ('\\' diagonal)\nd2 = sum_c |p01 - p10|    ('/' diagonal)"),
            row("C", "d1 + THRESH < d2 : split on p00-p11\nd2 + THRESH < d1 : split on p01-p10\notherwise (or EDGE_EN = 0): bilinear\n+ which triangle holds (fx, fy)"),
        ]),
        ("Weights", [row("G", "four integer weights for the chosen case\n(sum = ONE^2)")]),
        ("Interpolate", [
            row("M", "four products pixel * weight\nper component", True),
            row("S", "pairwise sums"),
            row("out", "(sum + ONE^2/2) >> 2*PB -> m_axis register"),
        ]),
    ],
    ipregs=("IP registers", ["0x040 THRESH [15:0]", "0x044 EDGE_CTRL [0] EDGE_EN\n(0 = identical to scaler_bilinear)"]),
    ipregs_to=["ph1"],
)


def polyphase_cfg(name, title, taps, lv, kernel, wrapper=None, tag=""):
    ns = 4 + lv + 1 + 1 + lv
    tap_txt = "TAPS = 2..16 (even)" if taps is None else f"TAPS = {taps}"
    generic = taps is None
    t = "TAPS" if generic else str(taps)
    lvs = "LV = ceil(log2 TAPS)" if generic else f"LV = {lv}"
    depth = f"{ns} = 6 + 2*LV stages" if not generic else "6 + 2*LV stages"
    mults = ("TAPS^2 + TAPS multipliers per component" if generic
             else f"{taps*taps} + {taps} = {taps*taps + taps} multipliers per component ({3*(taps*taps+taps)} for 3 components)")
    return dict(
        name=name, title=title, wrapper=wrapper,
        subtitle=f"separable polyphase FIR, {tap_txt}, programmable coefficient tables - {kernel}\n"
                 f"1 output pixel per clock - pipeline: {depth} + output register ({lvs})\n" + PIXEL,
        prep_title="quantise to the phase grid",
        prep_rows=["s_r = s + 2^(15 - PB)   (PB = PHASE_BITS = 6)", f"i = s_r >> 16 ; window origin = i - (TAPS/2 - 1)",
                   "px, py = s_r[15 : 16-PB]  (phases)"],
        taps=8 if generic else taps, fb_sub="TAPS = 8 shown" if generic else None,
        dp_sub=("A B W M1 T1..TLV S1 M2 H1..HLV: 6 + 2*LV stages" if generic else f"{ns} stages + output register (LV = {lv})"),
        phases=[
            ("Window", [row("W", f"{t} x {t} window register")]),
            ("Vertical FIR (per column k)", [
                row("M1", f"pixel * CV[py][j]\n{t}x{t} products per component", True),
                row("T1..TLV", "adder tree: one registered\nlevel per pairwise add"),
                row("S1", "v_k = (sum + 2^(F-1)) >> F"),
            ]),
            ("Horizontal FIR", [
                row("M2", f"v_k * CH[px][k]\n{t} products per component", True),
                row("H1..HLV", "adder tree, one level per stage"),
            ]),
            ("Output", [
                row("out", "(sum + 2^(F-1)) >> F\nclamp to [0, 2^COMP_W - 1]"),
                "-> m_axis register",
                mults,
            ]),
        ],
        tables=("Coefficient tables (signed, COEF_W = 16, F = COEF_FRAC = 14)", [
            "CH: horizontal, 2^PB phases x TAPS   0x1000 + 4*(16*phase + tap)",
            "CV: vertical,   2^PB phases x TAPS   0x2000 + 4*(16*phase + tap)",
            "reset value: bilinear weights; write while idle",
            "0x040 COEF_INFO (RO): TAPS, PHASE_BITS, COEF_W, COEF_FRAC",
        ]),
        tables_to=["ph1", "ph2"], tables_label="rows selected by\nphase (stage B)",
    )


POLY = polyphase_cfg("scaler_polyphase", "scaler_polyphase - generic separable polyphase scaler", None, 3,
                     "engine of scaler_bicubic and scaler_lanczos")
BICUBIC = polyphase_cfg("scaler_bicubic", "scaler_bicubic - bicubic (4x4) scaler", 4, 2,
                        "any Mitchell-Netravali (B, C) cubic: Catmull-Rom, Mitchell, B-spline, Keys",
                        wrapper="u_core: scaler_polyphase (TAPS = 4, IP_ID BCUB)")
LANCZOS = polyphase_cfg("scaler_lanczos", "scaler_lanczos - Lanczos-3 (6x6) scaler", 6, 3,
                        "windowed-sinc kernel, Lanczos-3 (Lanczos-2 tables also fit)",
                        wrapper="u_core: scaler_polyphase (TAPS = 6, IP_ID LANC)")


# -----------------------------------------------------------------------------
# mip-map scalers
# -----------------------------------------------------------------------------
def mip_diagram(name, title, wrapper, aniso, levels, kernel_note):
    d = Dot(name)
    d.port("s_axil", "s_axil\nAXI4-Lite\n(control)")
    d.port("s_axis", "s_axis\nAXI4-Stream\nvideo in")
    d.port("m_axis", "m_axis\nAXI4-Stream\nvideo out")
    d.open_cluster("top", name + (" (wrapper)" if wrapper else ""), bold=True)
    if wrapper:
        d.open_cluster("core", wrapper, fill="#f3f4f6")
    add_regbus_ctrl(d)
    d.block("ipregs", "IP registers", [
        "0x040 LOD (8.8)   0x044 ANISO_LOG2",
        "0x048/0x04C PROBE_STEP_X/Y   (s16.16)",
        "0x050/0x054 PROBE_START_X/Y  (s16.16)",
        "0x058 MIP_INFO (RO)\n0x060 + 4k  LEVEL_SIZE[k] (RO)",
    ], "ctl")
    d.block("levels", "Mip pyramid: banked_framebuf x LEVELS", [
        "L0 = input frame (written by the capture)",
        f"L1 .. L{levels-1}: each half the size of the last",
        "W[k+1] = max(1, W[k] >> 1), likewise H",
        "each level gives a 2x2 window per clock",
        "PINGPONG = 1 double-buffers the pyramid",
    ], "mem", sub=f"LEVELS = {levels}")
    d.block("build", "Mip build engine", [
        row("G_IDLE", "wait for a captured frame"),
        row("G_MIP", "read the 2x2 block of level k at (2x, 2y)\nbox filter: (a + b + c + d + 2) >> 2\nwrite it to level k+1"),
        row("G_DRAIN", "wait for the last write of the level;\nthen next level, or start sampling"),
        row("G_SAMPLE", "produce the output frame; back to\nG_IDLE when the last pixel is accepted"),
    ], "dp")
    add_dda(d)
    probes = ("1 probe per pixel (ANISO_MAX_LOG2 = 0)" if aniso == 0 else
              f"NP = 2^ANISO_LOG2 probes per pixel (up to {1 << aniso})")
    d.block("probe", "Probe stage P", [
        "p = src + PROBE_START + n * PROBE_STEP",
        probes,
        "the DDA advances once per pixel",
    ], "dp")
    d.block("lodsel", "Level select + coordinates", [
        "L = LOD[15:8], f = LOD[7:0]",
        "lvl_a = L, lvl_b = L + 1 (top level: f = 0)",
        "u_k = ((u + 0.5) >> k) - 0.5, both levels",
        "-> window origin and phases per level",
    ], "dp")
    d.block("samp", "Sampling pipeline", [
        row("A, B", "window origins of both levels; RAM data"),
        row("W", "level windows after the level muxes"),
        row("M1", "p*(ONE-fx), p*fx   both levels", True),
        row("S1", "top / bottom row sums"),
        row("M2", "top*(ONE-fy), bot*fy   both levels", True),
        row("S2", "bilinear samples sa, sb\n(sum + ONE^2/2) >> 2*PB"),
        row("M3", "sa*(256-f), sb*f   (trilinear blend)", True),
        row("out", "t = (sum + 128) >> 8\naccumulate over the probes of a pixel\n" +
            ("(one probe: t is the output pixel)" if aniso == 0 else "mean: (sum + NP/2) >> ANISO_LOG2")),
    ], "dp", sub="8 stages (A B W M1 S1 M2 S2 M3) + output stage")
    if wrapper:
        d.close()
    d.close()
    d.same("s_axil", "s_axis")
    d.same("regbus", "ctrl")
    d.same("build", "dda", "ipregs")
    d.same("probe", "lodsel")
    d.edge("s_axil", "regbus", "AXI4-Lite")
    d.edge("s_axis", "ctrl", "AXI4-Stream\nvideo in")
    d.edge("regbus", "ctrl", "register bus")
    d.edge("ctrl", "build", "gen_start", style="dashed", color="#6b7280")
    d.edge("ctrl", "dda", "sizes, STEP, OFFS", style="dashed", color="#6b7280")
    d.edge("ctrl", "ipregs", "ext bus", style="dashed", color="#6b7280")
    d.edge("build", "dda", "start sampling", style="dashed", color="#6b7280")
    d.edge("ctrl", "levels", "write port: L0", extra=", constraint=false")
    d.edge("build", "levels", "read L(k)\nwrite L(k+1)")
    d.edge("dda", "probe", "source x, y")
    d.edge("ipregs", "probe", "probe step\n/ start", style="dashed", color="#16a34a")
    d.edge("ipregs", "lodsel", "LOD", style="dashed", color="#16a34a", extra=", constraint=false")
    d.edge("probe", "lodsel")
    d.edge("lodsel", "levels", "window origins,\nphases")
    d.edge("levels", "samp", "windows")
    d.edge("samp", "m_axis", "AXI4-Stream\nvideo out")
    d.edge("samp", "ctrl", "gen_done", style="dashed", color="#6b7280", extra=", constraint=false")
    thr = ("1 probe per clock: an output pixel takes NP clocks (one for trilinear)" if aniso else
           "1 probe per clock = 1 output pixel per clock")
    sub = (f"mip pyramid built in hardware (2x2 box filter), trilinear sampling{kernel_note}\n"
           f"{thr} - latency: one input frame + mip build (about W*H/3 clocks)\n" + PIXEL)
    return d.render(title, sub)


# -----------------------------------------------------------------------------
# sharpen_cas
# -----------------------------------------------------------------------------
def cas_diagram():
    d = Dot("sharpen_cas")
    d.port("s_axil", "s_axil\nAXI4-Lite\n(control)")
    d.port("s_axis", "s_axis\nAXI4-Stream\nvideo in")
    d.port("m_axis", "m_axis\nAXI4-Stream\nvideo out")
    d.open_cluster("top", "sharpen_cas", bold=True)
    d.block("regbus", "axil_regbus", ["AXI4-Lite slave -> one-cycle register bus"], "ctl")
    d.block("regs", "Registers", [
        "0x000 CTRL [0] ENABLE [1] BYPASS",
        "0x004 STATUS  BUSY, FRAME_DONE*,\nSOF_ERR*, EOL_ERR*   (* write 1 to clear)",
        "0x008 SIZE (width, height)\n0x020 FRAME_CNT   0x028 CAPS",
        "0x024 IP_ID 'SHRP'   0x02C MAX_SIZE",
        "0x040 SHARPNESS  0..256",
    ], "ctl")
    d.block("inp", "Input side", [
        "first beat must carry tuser: data before SOF\nis dropped (SOF_ERR); tlast must mark the last\ncolumn (EOL_ERR)",
        "SIZE and SHARPNESS latched at start of frame",
        "column / row write counters",
        "input stalls when all four line buffers are in use",
    ], "ctl")
    d.block("lb", "Line buffers x 4", [
        "row r is stored in buffer (r mod 4)",
        "each MAX_W pixels: one write, one read port",
        "block RAM: about two lines of latency,\nno frame buffer",
    ], "mem")
    d.block("outeng", "Output engine", [
        "output row oy, read column oj = 0..W",
        "waits until the rows needed for oy have arrived",
        "W + 1 clocks per line: 1 pixel per clock",
    ], "ctl")
    d.block("roms", "ROM tables (lookup, no logic)", [
        "recip_rom: round(2^24 / v), v = 0 .. 2M",
        "sqrt_rom:  round(16 * sqrt(a)), a = 0 .. 256",
        "gain_rom:  round(65536 / (1024 - 3*SHARPNESS))",
    ], "mem")
    d.block("dp", "Pipelined datapath", [
        sec("Front end"),
        row("0", "read address, row selects"),
        row("1", "RAM read: all four buffers, same column"),
        row("2", "3x3 window shift register w[row][col]\n(edges clamp); centre e goes on a delay line"),
        sec("Amplitude (per component)"),
        row("X1", "5-tap cross and 4-corner min / max\nlap = 4e - b - d - f - h"),
        row("X2", "soft min mn = min5 + min9\nsoft max mx = max5 + max9\nhead = min(mn, 2M - mx)"),
        row("R1", "recip = recip_rom[mx]"),
        row("X3", "head * recip", True),
        row("X4", "amp = min(256, (prod + 2^15) >> 16)\n0 when mx = 0"),
        sec("Strength"),
        row("R2", "sq = sqrt_rom[amp]"),
        row("Y1", "k = (sq * gain + 128) >> 8", True),
        row("Y2", "kd = (k * lap + 128) >>> 8", True),
        sec("Apply"),
        row("out", "v = e + kd   (v = e when BYPASS)\nclamp to [0, M] -> m_axis register"),
    ], "dp", sub="stages 0-2, X1-X4, R1, R2, Y1, Y2 + output register")
    d.close()
    d.same("s_axil", "s_axis")
    d.same("regbus", "regs", "inp")
    d.same("lb", "outeng")
    d.same("dp", "roms")
    d.edge("s_axil", "regbus", "AXI4-Lite")
    d.edge("regbus", "regs", "register bus")
    d.edge("s_axis", "inp", "AXI4-Stream\nvideo in")
    d.edge("regs", "inp", "SIZE, SHARPNESS,\nENABLE", style="dashed", color="#6b7280")
    d.edge("inp", "lb", "write rows")
    d.edge("inp", "outeng", "rows received", style="dashed", color="#6b7280")
    d.edge("lb", "dp", "4 rows")
    d.edge("outeng", "dp", "column, row")
    d.edge("roms", "dp", "recip / sqrt / gain", style="dashed", color="#d97706")
    d.edge("regs", "dp", "BYPASS, SHARPNESS", style="dashed", color="#16a34a", extra=", constraint=false")
    d.edge("dp", "m_axis", "AXI4-Stream\nvideo out")
    sub = ("contrast-adaptive sharpening after AMD FidelityFX CAS: more enhancement where there is headroom, less near clipping or on strong edges\n"
           "same-size in / out - 3x3 neighbourhood - line-buffer architecture, about two lines of latency - 1 pixel per clock\n" + PIXEL)
    return d.render("sharpen_cas - contrast-adaptive sharpening", sub)


# -----------------------------------------------------------------------------
# spatial_upscaler
# -----------------------------------------------------------------------------
def spatial_diagram():
    d = Dot("spatial_upscaler")
    d.port("s_axil", "s_axil\nAXI4-Lite\n(ADDR_W = 15)")
    d.port("s_axis", "s_axis\nAXI4-Stream\nvideo in\n(MAX_W x MAX_H)")
    d.port("m_axis", "m_axis\nAXI4-Stream\nvideo out\n(OUT_W x OUT_H)")
    d.open_cluster("top", "spatial_upscaler", bold=True)
    d.block("split", "axil_split", [
        "address bit 14 selects the slave:",
        "0x0000-0x3FFF -> scaler_lanczos",
        "0x4000-0x40FF -> sharpen_cas",
        "AW / W held until both are present",
    ], "ctl")
    d.block("note", "Programming order", [
        "the sharpener SIZE (0x4008) must equal\nthe scaler OUT_SIZE: program the sharpener\nand enable it before enabling the scaler",
    ], "note")
    d.open_cluster("scal", "u_scaler: scaler_lanczos", fill="#f3f4f6")
    d.block("sctrl", "scaler_ctrl + scaler_dda", [
        "registers: common map, COEF_INFO 0x040,\nH table 0x1000, V table 0x2000",
        "capture FSM, frame sequencing",
        "output raster scan -> source coordinates",
    ], "ctl")
    d.block("sfb", "banked_framebuf", [
        "6x6 window per clock (8 x 8 RAM banks)",
        "sized for the input: MAX_W x MAX_H",
        "frame buffer | ping-pong | line buffer\n(PINGPONG / LINE_BUF parameters)",
    ], "mem")
    d.block("sdp", "6x6 polyphase datapath", [
        "vertical FIR -> horizontal FIR -> clamp",
        "programmable Lanczos-3 coefficient tables",
        "1 output pixel per clock, any size change",
    ], "dp")
    d.close()
    d.open_cluster("shrp", "u_sharpen: sharpen_cas", fill="#f3f4f6")
    d.block("sin", "Registers + input side", [
        "axil_regbus, SIZE, SHARPNESS, BYPASS",
        "SOF / EOL checks, back-pressure",
    ], "ctl")
    d.block("slb", "Line buffers x 4", [
        "sized for the output width: OUT_MAX_W",
        "about two lines of latency",
    ], "mem")
    d.block("scas", "3x3 window + CAS datapath", [
        "front end: read address, RAM read,\n3x3 shift register (edges clamp)",
        "amplitude -> strength -> apply",
        "1 pixel per clock",
    ], "dp")
    d.close()
    d.close()
    d.same("s_axil", "s_axis")
    d.same("split", "note")
    d.same("sin", "slb")
    d.edge("s_axil", "split", "AXI4-Lite")
    d.edge("split", "sctrl", "m0: scaler\nregisters", style="dashed", color="#6b7280")
    d.edge("split", "sin", "m1: sharpener\nregisters", style="dashed", color="#6b7280", extra=", constraint=false")
    d.edge("s_axis", "sctrl", "AXI4-Stream\nvideo in")
    d.edge("sctrl", "sfb", "write port,\nwindow origin, phases")
    d.edge("sfb", "sdp", "6x6 window")
    d.edge("sdp", "sin", "AXI4-Stream\nupscaled video\n(mid_t*)")
    d.edge("sin", "slb", "write rows")
    d.edge("slb", "scas", "4 rows")
    d.edge("scas", "m_axis", "AXI4-Stream\nvideo out")
    d.edge("sdp", "sctrl", "gen_done", style="dashed", color="#6b7280", extra=", constraint=false")
    sub = ("FSR 1-style spatial upscaler: Lanczos resampling followed by contrast-adaptive sharpening, behind one AXI4-Lite port\n"
           "s_axis -> scaler_lanczos (any size change) -> sharpen_cas -> m_axis - 1 pixel per clock end to end\n" + PIXEL)
    return d.render("spatial_upscaler - Lanczos + contrast-adaptive sharpening", sub)



# -----------------------------------------------------------------------------
# facts the diagrams state about the RTL; --check verifies each one still holds
# -----------------------------------------------------------------------------
RTL_FACTS = [
    # (ip, regular expression that must match in <ip>/src/<ip>.sv, what the diagram says)
    ("scaler_bilinear",      r"localparam int NST\s*=\s*6;", "6 pipeline stages (A B W M1 S1 M2)"),
    ("scaler_edge_directed", r"localparam int NST\s*=\s*8;", "8 pipeline stages (A B W D C G M S)"),
    ("scaler_edge_directed", r"8'h40:\s*thresh", "THRESH at 0x040"),
    ("scaler_edge_directed", r"8'h44:\s*edge_en", "EDGE_CTRL at 0x044"),
    ("scaler_mip",           r"localparam int NST\s*=\s*8;", "8 sampling stages (A B W M1 S1 M2 S2 M3)"),
    ("scaler_mip",           r"G_IDLE, G_MIP, G_DRAIN, G_SAMPLE", "mip build FSM states"),
    ("scaler_polyphase",     r"localparam int NST\s*=\s*4 \+ LV \+ 1 \+ 1 \+ LV;", "6 + 2*LV pipeline stages"),
    ("scaler_bicubic",       r"\.TAPS\(4\)", "TAPS = 4"),
    ("scaler_lanczos",       r"\.TAPS\(6\)", "TAPS = 6"),
    ("scaler_trilinear",     r"\.ANISO_MAX_LOG2\(0\)", "no anisotropic probes"),
    ("scaler_trilinear",     r"parameter int LEVELS\s*=\s*4", "LEVELS = 4"),
    ("scaler_anisotropic",   r"\.ANISO_MAX_LOG2\(4\)", "up to 16 probes"),
    ("scaler_anisotropic",   r"parameter int LEVELS\s*=\s*5", "LEVELS = 5"),
    ("spatial_upscaler",     r"\.SEL_BIT\(14\)", "address bit 14 selects the slave"),
    ("spatial_upscaler",     r"parameter int ADDR_W\s*=\s*15", "ADDR_W = 15"),
    ("spatial_upscaler",     r"scaler_lanczos\s+#\(", "the scaler stage is scaler_lanczos"),
] + [("sharpen_cas", r"^\s*//\s+" + t + r"\s", f"pipeline stage {t}") for t in
     ("X1", "X2", "R1", "X3", "X4", "R2", "Y1", "Y2")]


def check_rtl_facts():
    import re
    bad = 0
    for ip, rx, what in RTL_FACTS:
        path = os.path.join(ROOT, ip, "src", ip + ".sv")
        text = open(path).read()
        if not re.search(rx, text, re.M):
            print(f"RTL no longer matches the diagram: {ip}: {what}  (pattern {rx!r})")
            bad += 1
    return bad


# -----------------------------------------------------------------------------
DIAGRAMS = {
    "scaler_nearest": lambda: scaler_diagram(NEAREST),
    "scaler_bilinear": lambda: scaler_diagram(BILINEAR),
    "scaler_edge_directed": lambda: scaler_diagram(EDGE),
    "scaler_polyphase": lambda: scaler_diagram(POLY),
    "scaler_bicubic": lambda: scaler_diagram(BICUBIC),
    "scaler_lanczos": lambda: scaler_diagram(LANCZOS),
    "scaler_mip": lambda: mip_diagram(
        "scaler_mip", "scaler_mip - mip-map scaler engine (trilinear / anisotropic)", None, 4, 4,
        ", optional anisotropic probes (LEVELS, ANISO_MAX_LOG2)"),
    "scaler_trilinear": lambda: mip_diagram(
        "scaler_trilinear", "scaler_trilinear - trilinear scaler", "u_core: scaler_mip (LEVELS = 4, ANISO_MAX_LOG2 = 0, IP_ID TRIL)",
        0, 4, ""),
    "scaler_anisotropic": lambda: mip_diagram(
        "scaler_anisotropic", "scaler_anisotropic - anisotropic scaler",
        "u_core: scaler_mip (LEVELS = 5, ANISO_MAX_LOG2 = 4, IP_ID ANIS)", 4, 5,
        " with up to 16 probes along the major axis"),
    "sharpen_cas": cas_diagram,
    "spatial_upscaler": spatial_diagram,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ips", nargs="*", help="IP directories (default: all)")
    ap.add_argument("--dot-only", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    names = a.ips or list(DIAGRAMS)
    stale = 0
    for n in names:
        if n not in DIAGRAMS:
            sys.exit(f"unknown IP {n}; choose from: {', '.join(DIAGRAMS)}")
        text = DIAGRAMS[n]()
        outdir = os.path.join(ROOT, n, "doc")
        dotf = os.path.join(outdir, "block_diagram.dot")
        if a.check:
            old = open(dotf).read() if os.path.exists(dotf) else None
            if old != text:
                print(f"out of date: {dotf}")
                stale += 1
            continue
        os.makedirs(outdir, exist_ok=True)
        with open(dotf, "w") as f:
            f.write(text)
        if not a.dot_only:
            subprocess.run(["dot", "-Tsvg", dotf, "-o", os.path.join(outdir, "block_diagram.svg")], check=True)
        print(f"{n}: {os.path.relpath(dotf, ROOT)}" + ("" if a.dot_only else " + .svg"))
    if a.check:
        stale += check_rtl_facts()
        print("block diagrams up to date and consistent with the RTL" if not stale
              else f"{stale} problem(s): update tools/docs/make_block_diagrams.py and re-run it")
        sys.exit(1 if stale else 0)


if __name__ == "__main__":
    main()
