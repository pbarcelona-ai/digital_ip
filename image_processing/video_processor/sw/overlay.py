"""video_processor firmware: symbol_overlay, the tracking boxes and the text.

Object c * NTR + k is the symbol of target k of object class c: every symbol the same size (17 x 17
pixels at 320, scaled with the frame: symbol_scale) on the target's predicted centre, whatever the target's size, 1 pixel wide, in
the class's colour (people white, ground transport red, aircraft green) and in the style chosen for
the class (camera register 0x51 + c, det_style): 0 dashed rectangle (dashes of 4), 1 solid
rectangle, 2 dashed circle, 3 solid circle (symbol_overlay shape 3: round the box centre, radius
half the larger side), 4 dashed oval, 5 solid oval (shape 3 with OVAL: an ellipse inside the box, so
a long vehicle gets a long oval), 6 a solid box on the target's centre, 7 dashed rectangle with
solid corners, 8 the same with a 2-pixel tick at the middle of each side pointing to the centre, 9
dashed triangle with solid vertices. Defaults (the testbench's): people (pedestrian, face) 7, ground
transport (automobile, vehicle) 8, aircraft 9. Each target has a label below its symbol (OBJ_LABEL,
the 3 x 5 font at 2x to 8x by the frame size, symbol_scale): P<n> a person (pedestrian, or a face not inside one; a face
inside a pedestrian's box carries the pedestrian's label and is drawn instead of the body), G<n>
ground transport, A<n> an aircraft (upper case: clearer in the 3 x 5 font), n the lowest number no
live target of the group has (1 to the number of the group's targets in the scene; a target keeps
its label while it is tracked). Pedestrians and faces are drawn on top of the vehicles (lower object
numbers). Texts (3 x 5 font, on a darkened backdrop): T_NAME the image name in the upper left
corner, T_CLOCK a clock (time since the core logic started, HH:MM:SS.mmm) in the upper right,
T_FRAME "Frame Number <n>" in the lower left, the number counted by the overlay itself at every
frame start (exact on every frame). Changes are committed (overlay_commit), so they apply whole at
the next frame start.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

MARK_BASE = 8                      # symbol half size at 320 pixels: 2 x 8 + 1 = 17 pixels square, centred on its target
TRK_ON = 0x2109                    # dashed box: enabled rectangle outline, dashed, 1 pixel, dashes of 4
BOX_SOLID = 0x0101                 # enabled rectangle outline, 1 pixel
CIRC_DASHED = 0x210F               # enabled circle, dashed, 1 pixel, dashes of 4
CIRC_SOLID = 0x0107                # enabled circle, 1 pixel
OVAL_DASHED = 0x212F               # enabled oval (ellipse inside the box), dashed, 1 pixel, dashes of 4
OVAL_SOLID = 0x0127                # enabled oval, 1 pixel
BOX_CORNERS = TRK_ON | OBJ_CORNERS # dashed rectangle, solid corners
BOX_TICKS = BOX_CORNERS | OBJ_TICKS                    # + 2-pixel ticks towards the centre
TRI_DASHED = TRK_ON | OBJ_TRIANGLE # dashed triangle, solid vertices
TRK_GREEN = 0x00FF00               # stream pixel {B, G, R}: aircraft
TRK_RED = 0x0000FF                 # stream pixel {B, G, R}: ground transport (automobile, vehicle)
T_NAME = 0                         # text objects
T_CLOCK = 1
T_FRAME = 2
TXT_ON = 0x09                      # enabled, backdrop (scale in [2:1], length in [12:8])
TXT_FNUM = 0x10                    # + the frame number after the characters
WHITE = 0xFFFFFF
YELLOW = 0x00FFFF                  # stream pixel {B, G, R}
txt_sc = 0                         # text scale log2 (symbol_scale: by the frame size)
mark_half = MARK_BASE              # symbol half size: MARK_BASE x the frame's scale k (symbol_scale)
sym_lw = 1                         # symbol line width (OBJ_CTRL [11:8])
sym_dash = 2                       # dash length log2 (OBJ_CTRL [14:12])
lab_sc = 1                         # label scale log2 (CTRL [2:1])
rem = 0                            # remainder of the last div()


def class_colour(c):
    if c == C_AIR:
        return TRK_GREEN
    if c >= C_CAR:                                     # ground transport: red, told apart from people
        return TRK_RED
    return WHITE


def class_style(c):
    """Symbol style of class c (det_style bits 4c+3..4c)."""
    return (det_style >> (c << 2)) & 15


def symbol_scale():
    """Symbol, label and text sizes for the frame size: k = the longer side / 320 (rounded, at least 1);
    symbols 2 x 8k + 1 pixels with lines (2k + 1) / 3 wide and dashes 4 to 16 pixels, labels 2x / 4x / 8x
    the 3 x 5 font, texts 1x to 8x (so they read the same on a 320-pixel GIF and a 1920 x 1080 video)."""
    global mark_half, sym_lw, sym_dash, lab_sc, txt_sc
    m = cam_w
    if cam_h > m:
        m = cam_h
    k = (m + 160) // 320
    if k < 1:
        k = 1
    mark_half = MARK_BASE * k
    sym_lw = (2 * k + 1) // 3
    sym_dash = 2
    lab_sc = 1
    if k >= 2:
        sym_dash = 3
        lab_sc = 2
    if k >= 4:
        sym_dash = 4
        lab_sc = 3
    txt_sc = 0
    if m >= 256:
        txt_sc = 1
    if m >= 640:
        txt_sc = 2
    if m >= 1280:
        txt_sc = 3


def class_shape(c):
    """OBJ_CTRL of class c's symbols in its style, with the line width and dash length of the frame size."""
    return (class_ctrl(c) & ~0x7F00) | (sym_lw << 8) | (sym_dash << 12)


def class_ctrl(c):
    """OBJ_CTRL of class c's style at the base size (1-pixel lines, dashes of 4)."""
    s = class_style(c)
    if s == 1:
        return BOX_SOLID
    if s == 2:
        return CIRC_DASHED
    if s == 3:
        return CIRC_SOLID
    if s == 4:
        return OVAL_DASHED
    if s == 5:
        return OVAL_SOLID
    if s == 6:                                         # solid box in the middle of the target
        return BOX_SOLID
    if s == 7:
        return BOX_CORNERS
    if s == 8:
        return BOX_TICKS
    if s == 9:
        return TRI_DASHED
    return TRK_ON


def obj_index(c, k):
    """Overlay object number of class c's track k (c * NTR + k)."""
    i = k
    while c > 0:
        i += NTR
        c -= 1
    return i


def obj_addr(c, k):
    """Base address of overlay object c * NTR + k (its OBJ_CTRL at + OBJ_CTRL): objects 16-31 are the
    second bank (OBJ2_CTRL at 0x2A0)."""
    i = obj_index(c, k)
    if i < 16:
        return OVL + (i << 4)
    return OVL + OBJ2_CTRL - OBJ_CTRL + ((i - 16) << 4)


def obj_label(c, k):
    """Register address of the label of overlay object c * NTR + k (OBJ_LABEL, or OBJ2_LABEL from 16)."""
    i = obj_index(c, k)
    if i < 16:
        return OVL + OBJ_LABEL + (i << 2)
    return OVL + OBJ2_LABEL + ((i - 16) << 2)


def number_label(letter, n):
    """OBJ_LABEL word: the letter then n (1-999) in decimal, first character in the low byte."""
    if n < 10:
        return letter | ((48 + n) << 8)
    if n < 100:
        return letter | (two_digits(n) << 8)
    h = div(n, 100)
    return letter | ((48 + h) << 8) | (two_digits(rem) << 16)


def label_new(c, k, cx, cy):
    """Target k of class c just confirmed at centre cx, cy (pixels): its label. A face inside a labelled
    pedestrian's box, or just above it (the head over a dark body), takes the pedestrian's label (the
    face is drawn, the body hidden: tracking.py next_box); otherwise the lowest number no live target
    of its group has."""
    if c == C_FACE:
        j = 0
        t = det_base(C_PED)
        while j < NTR:
            b = track_word(j)
            if sc_get(t, b + SC_STATE) != S_SEARCH:
                x = sc_get(t, b + SC_CX)
                w = sc_get(t, b + SC_W)
                if (cx << 1) >= x - w and (cx << 1) <= x + w:
                    x = sc_get(t, b + SC_CY)
                    w = sc_get(t, b + SC_H)
                    if (cy << 1) >= x - w - (w >> 1) and (cy << 1) <= x + w:   # the head may top the box
                        x = mem32[obj_label(C_PED, j)]
                        if x:                          # the person's label: the face carries it while
                            mem32[obj_label(c, k)] = x   # it is tracked (the body's symbol is hidden)
                            return
            j += 1
    if c >= C_AIR:
        letter = 65                                    # "A"
        g = C_AIR
    elif c >= C_CAR:
        letter = 71                                    # "G"
        g = C_CAR
    else:
        letter = 80                                    # "P"
        g = C_PED
    used = labels_used(g, letter, c, k)
    n = 1
    while used & (1 << n):                             # the lowest number no live target of the group has
        n += 1
    mem32[obj_label(c, k)] = number_label(letter, n)


def labels_used(g, letter, c0, k0):
    """Bit n set: a live target of the group starting at class g (people: pedestrian, face; ground:
    automobile, vehicle; air: aircraft) other than target k0 of class c0 is labelled <letter><n>
    (n 1-9)."""
    used = 0
    c = g
    while c < NDET and (c == g or (g == C_PED and c == C_FACE) or (g == C_CAR and c == C_VEH)):
        t = det_base(c)
        j = 0
        while j < NTR:
            if (c != c0 or j != k0) and sc_get(t, track_word(j) + SC_STATE) != S_SEARCH:
                lab = mem32[obj_label(c, j)]
                if (lab & 255) == letter and ((lab >> 16) & 255) == 0:
                    used = used | (1 << (((lab >> 8) & 255) - 48))
            j += 1
        c += 1
    return used


def overlay_setup(name_len):
    """Overlay on: every target symbol of each selected class in its colour and hidden (no target
    yet), no labels, the other classes' symbols off, the texts (texts_setup)."""
    symbol_scale()
    c = 0
    while c < NDET:
        k = 0
        while k < NTR:
            o = obj_addr(c, k)
            wreg(o + OBJ_CTRL, 0, strings(
                "symbol_overlay OBJn_CTRL (n = class x 3 + target)",
                "0 = the target's symbol hidden: no target found yet", ""))
            wreg(obj_label(c, k), 0, strings(
                "symbol_overlay OBJn_LABEL",
                "0 = no label (given once a target is confirmed: P<n> person,",
                "G<n> ground transport, A<n> aircraft)"))
            if det_mask & (1 << c):
                wreg(o + OBJ_COLOR, class_colour(c), strings(
                    "symbol_overlay OBJn_COLOR",
                    "[23:0] pixel {B, G, R}: the class's symbol colour (people",
                    "white, ground transport red, aircraft green)"))
            k += 1
        c += 1
    texts_setup(name_len)
    text_clock(mem32[FC + FC_TIME])
    overlay_commit()
    wreg(OVL + OVL_CTRL, 1 | (lab_sc << 1) | OVL_FONT, strings(
        "symbol_overlay CTRL",
        "[0] overlay on, [2:1] labels 2x / 4x / 8x by the frame size,",
        "[3] FONT: labels and texts in the smooth (anti-aliased) font"))


def overlay_box(c, k, x0, y0, x1, y1):
    """The symbol of class c's target k in the box x0..x1, y0..y1 (inside the frame) in the class's
    style; applies at overlay_commit."""
    o = obj_addr(c, k)
    x1 = clip(x1, cam_w - 1)                           # computed first: few operands pending in a call
    x0 = clip(x0, cam_w - 1)
    y1 = clip(y1, cam_h - 1)
    y0 = clip(y0, cam_h - 1)
    wreg(o + OBJ_X, (x1 << 16) | x0, strings(
        "symbol_overlay OBJn_X",
        "symbol box columns [15:0] left, [31:16] right (17 pixels",
        "on the target's predicted centre, inside the frame)"))
    wreg(o + OBJ_Y, (y1 << 16) | y0, strings(
        "symbol_overlay OBJn_Y",
        "tracking box lines [15:0] top, [31:16] bottom", ""))
    wreg(o + OBJ_CTRL, class_shape(c), strings(
        "symbol_overlay OBJn_CTRL",
        "[0] on [2:1] 0 box / 3 circle [3] dashed [5] oval [6] ticks",
        "[7] triangle [11:8] width 1 [14:12] 2: dash 4 [15] corners"))


def overlay_off(c, k):
    wreg(obj_addr(c, k) + OBJ_CTRL, 0, strings(
        "symbol_overlay OBJn_CTRL",
        "0 = the target's box hidden (no target)", ""))


def overlay_commit():
    wreg(OVL + OVL_COMMIT, 1, strings(
        "symbol_overlay COMMIT",
        "write 1: the object and text registers written so far apply",
        "together at the next frame start (no half-updated frame)"))


# ---------------- text

def text_set(j, x, y, ctrl, colour):
    """Text j at x, y (top-left corner) with ctrl (TXT_ON, TXT_FNUM, length << 8) at the text scale."""
    b = OVL + (j << 4)
    wreg(b + TXT_POS, (y << 16) | x, strings(
        "symbol_overlay TXTn_POS",
        "text n = (offset - 0x154) / 16: top-left corner of the text,",
        "[15:0] x, [31:16] y in frame pixels"))
    wreg(b + TXT_COLOR, colour, strings(
        "symbol_overlay TXTn_COLOR",
        "[23:0] pixel {B, G, R} of the text's characters (white name /",
        "frame number, yellow clock)"))
    wreg(b + TXT_CTRL, ctrl | (txt_sc << 1), strings(
        "symbol_overlay TXTn_CTRL",
        "[0] text shown, [2:1] scale log2, [3] dark backdrop, [4] the",
        "frame number follows the characters, [12:8] characters"))


def text_word(j, q, word):
    """Characters 4q .. 4q+3 of text j (character 4q in the low byte)."""
    wreg(OVL + TXT_CHARS + (j << 4) + (q << 2), word, strings(
        "symbol_overlay TXTn_CHARS",
        "text n = (offset - 0x210) / 16: 4 ASCII characters of the",
        "text, the first in [7:0] (name, clock or \"frame number \")"))


def div(v, d):
    """v // d for v >= 0, d > 0 by shift and subtract (py_core has no divide); the remainder in rem."""
    global rem
    q = 0
    s = d
    b = 1
    while s <= v >> 1:
        s = s << 1
        b = b << 1
    while b:
        if v >= s:
            v = v - s
            q = q | b
        s = s >> 1
        b = b >> 1
    rem = v
    return q


def two_digits(v):
    """Characters of v (0-99) as two ASCII digits: tens in the low byte."""
    t = div(v, 10)
    return (48 + t) | ((48 + rem) << 8)


def text_clock(us):
    """T_CLOCK = HH:MM:SS.mmm of us microseconds."""
    s = div(us, 1000000)
    ms = div(rem, 1000)
    h = div(s, 3600)
    m = div(rem, 60)
    sec = rem
    hh = two_digits(h)
    mm = two_digits(m)
    ss = two_digits(sec)
    m2 = div(ms, 100)
    m10 = two_digits(rem)
    text_word(T_CLOCK, 0, hh | (58 << 16) | ((mm & 255) << 24))                   # "HH:M"
    text_word(T_CLOCK, 1, (mm >> 8) | (58 << 8) | (ss << 16))                     # "M:SS"
    text_word(T_CLOCK, 2, 46 | ((48 + m2) << 8) | (m10 << 16))                    # ".mmm"


def texts_setup(name_len):
    """Name (characters already written, name_len of them) upper left, clock upper right,
    "frame number <n>" lower left counting from 1 at the next frame."""
    text_set(T_NAME, 1, 1, TXT_ON | (name_len << 8), WHITE)
    text_set(T_CLOCK, cam_w - 1 - (48 << txt_sc), 1, TXT_ON | (12 << 8), YELLOW)
    text_word(T_FRAME, 0, 0x6D617246)                  # "Fram"
    text_word(T_FRAME, 1, 0x754E2065)                  # "e Nu"
    text_word(T_FRAME, 2, 0x7265626D)                  # "mber"
    text_word(T_FRAME, 3, 0x20)                        # " "
    text_set(T_FRAME, 1, cam_h - 1 - (6 << txt_sc), TXT_ON | TXT_FNUM | (13 << 8), WHITE)
    wreg(OVL + OVL_FNUM, 1, strings(                    # the first frame of the sequence is number 1
        "symbol_overlay FRAME_NUM",
        "BCD frame number shown by the frame-number text in the next",
        "frame: 1, then the overlay adds 1 at every frame start"))
