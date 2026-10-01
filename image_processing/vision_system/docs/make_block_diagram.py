#!/usr/bin/env python3
# ***************
# Filename: make_block_diagram.py
# Author: FPGA Cores 4 U
# Description: Generates docs/block_diagram.svg (and .png if cairosvg-3.13 is
# installed) showing the lens-distortion-correction core: interfaces,
# config plane, frame buffer, coord_gen fast/slow paths, bilinear and
# bicubic lanes, and output sequencing. Edit the layout below and rerun.
# Date: September 28, 2026
# ***************
"""Usage: python3 docs/make_block_diagram.py   (run from anywhere)"""
import os

W, H = 1500, 960
out = []

# colour classes: (fill, stroke)
C = {
    "if":   ("#eceff3", "#6b7280"),   # external interfaces
    "cfg":  ("#dbeafe", "#2563eb"),   # configuration plane
    "data": ("#dcfce7", "#16a34a"),   # datapath
    "mem":  ("#ffedd5", "#ea580c"),   # memory
    "ctl":  ("#ede9fe", "#7c3aed"),   # control / sequencing
    "ip":   ("#fef9c3", "#ca8a04"),   # shared IP / packages
}


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=12, weight="normal", anchor="middle", fill="#111827", italic=False):
    st = ' font-style="italic"' if italic else ""
    out.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
               f'text-anchor="{anchor}" fill="{fill}"{st}>{esc(s)}</text>')


def box(x, y, w, h, kind, title, lines=(), title_size=13, line_size=11, rx=8,
        container=False, dash=False):
    fill, stroke = C[kind]
    if container:
        fill = "none"
    d = ' stroke-dasharray="6 4"' if dash else ""
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
               f'fill="{fill}" stroke="{stroke}" stroke-width="{2 if container else 1.5}"{d}/>')
    if container:
        text(x + 10, y + 18, title, title_size, "bold", "start", stroke)
        ty = y + 18
    else:
        text(x + w / 2, y + 20, title, title_size, "bold", "middle", "#111827")
        ty = y + 20
    for i, ln in enumerate(lines):
        if container:
            text(x + 10, ty + 16 + i * 14, ln, line_size, "normal", "start", "#374151")
        else:
            text(x + w / 2, ty + 18 + i * 14, ln, line_size, "normal", "middle", "#374151")


MARKER_COLORS = set()


def mid(color):
    MARKER_COLORS.add(color)
    return color.lstrip("#")


def arrow(pts, color="#374151", dash=False, both=False, width=1.8, label=None,
          lx=None, ly=None, lsize=10.5, lanchor="middle", head=True):
    p = " ".join(f"{a},{b}" for a, b in pts)
    d = ' stroke-dasharray="6 4"' if dash else ""
    m = mid(color)
    ms = f' marker-start="url(#s_{m})"' if both else ""
    me = f' marker-end="url(#e_{m})"' if head else ""
    out.append(f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="{width}"{d}{me}{ms}/>')
    if label:
        text(lx if lx is not None else (pts[0][0] + pts[-1][0]) / 2,
             ly if ly is not None else (pts[0][1] + pts[-1][1]) / 2 - 5,
             label, lsize, "normal", lanchor, color, italic=True)


# ------------------------------------------------------------------ header
out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
           f'font-family="Helvetica, Arial, sans-serif">')
out.append("@@DEFS@@")
out.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
text(W / 2, 30, "Vision System Core - Block Diagram", 22, "bold")
text(W / 2, 48, "vision_system (top)  |  Q16.16 fixed point  |  RGB888  |  "
                "radial / fisheye / panoramic / perspective  |  bilinear / bicubic", 12,
     fill="#4b5563")

# ------------------------------------------------------------------ outer box
box(170, 62, 1230, 846, "if", "vision_system", container=True, title_size=14)

# ------------------------------------------------------------------ external interfaces
box(8, 120, 150, 70, "if", "AXI4-Lite slave", ["s_axil_*", "config / status"], rx=18)
box(8, 322, 150, 84, "if", "AXI4-Stream in", ["s_axis_*", "RGB888 + tlast/tuser", "line, then >=5 idle"], rx=18)
box(1410, 655, 88, 100, "if", "AXI4-Stream", ["out", "m_axis_*", "RGB888 +", "tlast/tuser"], rx=18, title_size=12)

# ------------------------------------------------------------------ config plane
box(190, 82, 700, 166, "cfg", "axi_lite_regs", container=True)
box(205, 112, 300, 126, "cfg", "Register file",
    ["CTRL / STATUS / IMG_WIDTH / IMG_HEIGHT", "K1-K3, P1-P2  (radial, tangential)",
     "FX FY CX CY, CALIB_MODE", "MODEL_SEL, INTERP_MODE", "H11-H32 (homography)"])
box(530, 112, 345, 126, "cfg", "Derived config (settle FSM)",
    ["cx, cy, fx, fy from centre / scale / size:", "mulq_s pipelines (6 mults, settle wait)",
     "2x fixed_recip  ->  1/fx , 1/fy", "pending re-run on any write mid-pass",
     "outputs cfg : calib_params_t"])

box(912, 82, 476, 78, "ip", "Shared packages",
    ["barrel_pkg: Q16.16, qmul / qsat / qsat48, MAX_W/H=720",
     "distortion_model_pkg: calib_params_t, model enum"], title_size=12)
box(912, 168, 476, 80, "ip", "mulq_s IP  (ip/mulq)",
    ["(a*b)>>>16 in 2 cycles: four 16x16 DSP partial", "products, then combine.  Used by coord_gen,",
     "bicubic and axi_lite_regs (all timing-critical multiplies)"], title_size=12)

# ------------------------------------------------------------------ input side
box(190, 296, 160, 122, "data", "axis_in_ctrl",
    ["AXI-S slave", "raster write address", "tuser -> addr 0", "capture_en gate"])
box(190, 452, 160, 96, "ctl", "Top FSM",
    ["T_LOAD  ->  T_OUTPUT", "capture_en / busy", "frame_out_done"])
box(390, 286, 200, 352, "mem", "frame_buffer",
    ["4x replicated RAMB36 banks", "720 x 720 x 24 bit each", "= 1,536 RAMB36E1", "",
     "1 write port (from axis_in_ctrl)", "4 read ports (2x2 corners, or",
     "one row of 4 taps per cycle)", "1-cycle synchronous read"])

# ------------------------------------------------------------------ axis_out_ctrl
box(650, 272, 740, 608, "data", "axis_out_ctrl", container=True)
box(668, 300, 190, 118, "ctl", "Raster generator",
    ["x, y counters, line gap", "req_outstanding pacing", "(bicubic and slow-path", "models: 1 pixel at a time)"])

box(890, 290, 486, 218, "data", "coord_gen", container=True)
box(902, 318, 232, 176, "data", "Fast path  (23 cycles)",
    ["MODEL_RADIAL (+ AFFINE/SCALING hooks)", "", "normalize: (x-cx)/fx via 1/fx",
     "r2, r4, r6  ->  radial factor", "tangential (p1, p2) terms",
     "sx = cx + n*factor*fx", "every multiply = mulq_s + qsat48", "1 request / clock"], title_size=12)
box(1146, 318, 218, 176, "data", "Slow path  (per-pixel divide)",
    ["FISHEYE / PANORAMIC / PERSPECTIVE", "",
     "PRE pipe: denominator (14 cyc)", "fixed_recip 1/den  (~35 cyc)",
     "POST pipe: sx, sy   (6 cyc)", "FSM only counts fixed depths", "1 pixel at a time"], title_size=12)

# read-port mux
box(655, 566, 76, 304, "mem", "Read-port", ["mux", "", "interp_", "mode", "", "picks", "which", "lane owns", "the 4", "read", "ports"],
    title_size=11, line_size=10.5)

# bilinear lane
box(775, 566, 222, 112, "data", "Address expand  (4 stages)",
    ["clamp-to-edge, int/frac split", "row base = y0 x width  (registered)", "4 corner read addresses"], title_size=12)
box(1030, 566, 178, 112, "data", "bilinear  (3 stages)",
    ["2x2 taps, 8-bit weights", "12 pixel x weight products", "then sum + round"], title_size=12)
# bicubic lane
box(775, 720, 222, 148, "data", "Bicubic gather FSM",
    ["lock clamped anchor + weights", "row base = (y0-1) x width", "  (registered), then += width",
     "4 sequential row reads,", "16 taps -> holding regs"], title_size=12)
box(1030, 720, 178, 148, "data", "bicubic  (18 stages)",
    ["bicubic_weights x2  (9 cyc)", "bicubic_row x12  (4 cyc)", "bicubic_col x3  (4 cyc)",
     "round, >>16, clamp 0..255", "Catmull-Rom 4x4"], title_size=12)
# output stage
box(1240, 566, 138, 302, "ctl", "Output stage",
    ["", "pixel select", "(interp_mode)", "", "tlast / tuser", "tag delay line",
     "88-deep shift reg", "", "tap by mode:", "bilinear   31", "bicubic     48", "slow+bil.  71", "slow+bic.  88"],
    title_size=12, line_size=10.5)

# ------------------------------------------------------------------ arrows
# AXI-Lite -> regs
arrow([(158, 155), (205, 155)], "#2563eb", label="", both=True)
# regs internal
arrow([(505, 175), (530, 175)], "#2563eb")
# cfg bus to coord_gen (and axis_out_ctrl)
arrow([(700, 248), (700, 262), (1133, 262), (1133, 290)], "#2563eb", width=2.4,
      label="cfg : calib_params_t  +  img_width/height, interp_mode, 1/fx, 1/fy",
      lx=910, ly=257)
# stream in
arrow([(158, 364), (190, 364)], "#6b7280")
# axis_in_ctrl -> frame buffer write
arrow([(350, 362), (390, 362)], "#ea580c", width=2.4)
text(370, 352, "wr", 10, fill="#ea580c")
# FSM <-> in ctrl
arrow([(270, 452), (270, 418)], "#7c3aed", label="capture_en", lx=298, ly=440, lanchor="start")
# FSM -> axis_out_ctrl (dashed control path around the bottom)
arrow([(270, 548), (270, 894), (1020, 894), (1020, 880)], "#7c3aed", dash=True, width=1.6)
text(470, 888, "start_output  /  busy, frame_out_done  (control)", 10.5, fill="#7c3aed", italic=True)
# raster -> coord_gen
arrow([(858, 359), (890, 359)], "#374151", label="req x,y", lx=874, ly=350, lsize=9.5)
# coord_gen -> sx,sy trunk: feeds the address-expand top edge and, through the
# gap between the two lanes' boxes, the bicubic gather FSM
arrow([(1133, 508), (1133, 540), (886, 540), (886, 566)], "#16a34a", width=2.4)
arrow([(1013, 540), (1013, 699), (886, 699), (886, 720)], "#16a34a", width=2.0)
text(1130, 534, "sx, sy  (Q16.16 source coordinate)", 10.5, anchor="end", fill="#15803d", italic=True)
# lane arrows
arrow([(997, 622), (1030, 622)], "#16a34a", width=2)
arrow([(997, 794), (1030, 794)], "#16a34a", width=2)
# mux <-> lanes (addr left, data right)  -- corridor between mux(731) and lanes(775)
arrow([(775, 596), (731, 596)], "#ea580c", label="addr", lx=753, ly=590, lsize=9)
arrow([(731, 654), (775, 654)], "#ea580c", label="data", lx=753, ly=648, lsize=9)
arrow([(775, 830), (731, 830)], "#ea580c", label="addr", lx=753, ly=824, lsize=9)
arrow([(731, 858), (775, 858)], "#ea580c", label="data", lx=753, ly=852, lsize=9)
# mux <-> frame buffer (double)
arrow([(655, 590), (590, 590)], "#ea580c", width=2.4)
arrow([(590, 620), (655, 620)], "#ea580c", width=2.4)
text(622, 582, "4 rd addr", 9.5, fill="#c2410c", italic=True)
text(622, 636, "4 rd data", 9.5, fill="#c2410c", italic=True)
# interpolators -> output stage
arrow([(1208, 622), (1240, 622)], "#16a34a", width=2)
arrow([(1208, 794), (1240, 794)], "#16a34a", width=2)
# output stage -> AXI-S out
arrow([(1378, 705), (1410, 705)], "#6b7280", width=2.2)
# control from raster gen down to out stage is via tags (note)
arrow([(700, 418), (700, 522), (1309, 522), (1309, 566)], "#7c3aed", dash=True, width=1.4)
text(712, 517, "req_tlast / req_tuser -> tag delay line", 10, anchor="start", fill="#7c3aed", italic=True)

# ------------------------------------------------------------------ legend
lx0, ly0 = 190, 924
items = [("if", "external interface"), ("cfg", "configuration plane"), ("data", "datapath"),
         ("mem", "memory"), ("ctl", "control / sequencing"), ("ip", "shared IP / packages")]
x = lx0
for k, label in items:
    fill, stroke = C[k]
    out.append(f'<rect x="{x}" y="{ly0-11}" width="20" height="14" rx="3" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
    text(x + 26, ly0, label, 11.5, anchor="start")
    x += 30 + len(label) * 7 + 22
text(1490, ly0, "solid = data / config    dashed = control", 11.5, anchor="end", fill="#4b5563")

defs = ["<defs>"]
for c in sorted(MARKER_COLORS):
    m = c.lstrip("#")
    defs.append(f'<marker id="e_{m}" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="7" refX="8" refY="3.5" orient="auto"><path d="M0,0 L9,3.5 L0,7 z" fill="{c}"/></marker>')
    defs.append(f'<marker id="s_{m}" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="7" refX="1" refY="3.5" orient="auto-start-reverse"><path d="M0,0 L9,3.5 L0,7 z" fill="{c}"/></marker>')
defs.append("</defs>")
out[out.index("@@DEFS@@")] = "".join(defs)
out.append("</svg>")

here = os.path.dirname(os.path.abspath(__file__))
svg_path = os.path.join(here, "block_diagram.svg")
with open(svg_path, "w") as f:
    f.write("\n".join(out))
print("wrote", svg_path)
#try:
#    import cairosvg
#    png_path = os.path.join(here, "block_diagram.png")
#    cairosvg.svg2png(url=svg_path, write_to=png_path, scale=1.4)
#    print("wrote", png_path)
#except ImportError:
#    print("cairosvg not installed: PNG skipped (pip install cairosvg)")
