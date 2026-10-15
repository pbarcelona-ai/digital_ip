"""video_processor firmware: symbol_overlay, the tracking boxes and the text.

Object c * NTR + k is the box of target k of object class c, TRK_PAD pixels outside the target, 1
pixel wide, in the class's colour (pedestrian green, face magenta, automobile cyan, vehicle orange)
and in the style chosen for the class (camera register 0x51 + c, det_style): 0 dashed rectangle
(dashes of 4), 1 solid rectangle, 2 dashed circle, 3 solid circle (symbol_overlay shape 3: round
the box centre, radius half the larger side), 4 dashed oval, 5 solid oval (shape 3 with OVAL: an
ellipse inside the box, so a long vehicle gets a long oval), 6 a solid box in the middle of the
target (a quarter of its size, at least 8 pixels: large targets such as cars and trains are marked,
not outlined). Pedestrians and faces are drawn on
top of the vehicles (lower object numbers). Texts (3 x 5 font, on a darkened backdrop): T_NAME the image name in the upper left
corner, T_CLOCK a clock (time since the core logic started, HH:MM:SS.mmm) in the upper right, T_FRAME
"frame number <n>" in the lower left, the number counted by the overlay itself at every frame start
(exact on every frame). Changes are committed (overlay_commit), so they apply whole at the next
frame start.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

TRK_PAD = 2                        # dashed box: 2 pixels outside the target
TRK_ON = 0x2109                    # dashed box: enabled rectangle outline, dashed, 1 pixel, dashes of 4
BOX_SOLID = 0x0101                 # enabled rectangle outline, 1 pixel
CIRC_DASHED = 0x210F               # enabled circle, dashed, 1 pixel, dashes of 4
CIRC_SOLID = 0x0107                # enabled circle, 1 pixel
OVAL_DASHED = 0x212F               # enabled oval (ellipse inside the box), dashed, 1 pixel, dashes of 4
OVAL_SOLID = 0x0127                # enabled oval, 1 pixel
TRK_GREEN = 0x00FF00               # stream pixel {B, G, R}: pedestrian
MAGENTA = 0xFF00FF                 # face
CYAN = 0xFFFF00                    # automobile
ORANGE = 0x0080FF                  # vehicle
T_NAME = 0                         # text objects
T_CLOCK = 1
T_FRAME = 2
TXT_ON = 0x09                      # enabled, backdrop (scale in [2:1], length in [12:8])
TXT_FNUM = 0x10                    # + the frame number after the characters
WHITE = 0xFFFFFF
YELLOW = 0x00FFFF                  # stream pixel {B, G, R}
txt_sc = 0                         # text scale log2: 1x below 256 pixels across, else 2x
rem = 0                            # remainder of the last div()


def class_colour(c):
    if c == C_PED:
        return TRK_GREEN
    if c == C_FACE:
        return MAGENTA
    if c == C_CAR:
        return CYAN
    return ORANGE


def class_style(c):
    """Box style of class c (det_style bits 3c+2..3c)."""
    return (det_style >> ((c << 1) + c)) & 7


def class_shape(c):
    """OBJ_CTRL of class c's boxes in its style."""
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
    return TRK_ON


def obj_addr(c, k):
    """Register address of overlay object c * NTR + k (class c, track k)."""
    o = OVL + (k << 4)
    while c > 0:
        o += NTR << 4
        c -= 1
    return o


def overlay_setup(name_len):
    """Overlay on: every target box of each selected class in its colour and hidden (no target
    yet), the other classes' boxes off, the texts (texts_setup)."""
    c = 0
    while c < NTRK:
        k = 0
        while k < NTR:
            o = obj_addr(c, k)
            wreg(o + OBJ_CTRL, 0, strings(
                "symbol_overlay OBJn_CTRL (n = class x 3 + target)",
                "0 = the target's box hidden: no target found yet", ""))
            if det_mask & (1 << c):
                wreg(o + OBJ_COLOR, class_colour(c), strings(
                    "symbol_overlay OBJn_COLOR",
                    "[23:0] pixel {B, G, R}: the class's box colour (pedestrian",
                    "green, face magenta, automobile cyan, vehicle orange)"))
            k += 1
        c += 1
    texts_setup(name_len)
    text_clock(mem32[FC + FC_TIME])
    overlay_commit()
    wreg(OVL + OVL_CTRL, 1, strings(
        "symbol_overlay CTRL",
        "[0] overlay on: the committed objects and texts are drawn over",
        "every frame on its way to the display"))


def overlay_box(c, k, x0, y0, x1, y1):
    """The box of class c's target k around x0..x1, y0..y1 (TRK_PAD outside, inside the frame) in
    the class's style; applies at overlay_commit."""
    o = obj_addr(c, k)
    x1 = clip(x1 + TRK_PAD, cam_w - 1)                 # computed first: few operands pending in a call
    x0 = clip(x0 - TRK_PAD, cam_w - 1)
    y1 = clip(y1 + TRK_PAD, cam_h - 1)
    y0 = clip(y0 - TRK_PAD, cam_h - 1)
    wreg(o + OBJ_X, (x1 << 16) | x0, strings(
        "symbol_overlay OBJn_X",
        "tracking box columns [15:0] left, [31:16] right (2 pixels",
        "outside the target, inside the frame)"))
    wreg(o + OBJ_Y, (y1 << 16) | y0, strings(
        "symbol_overlay OBJn_Y",
        "tracking box lines [15:0] top, [31:16] bottom", ""))
    wreg(o + OBJ_CTRL, class_shape(c), strings(
        "symbol_overlay OBJn_CTRL",
        "[0] shown, [2:1] 0 rectangle / 3 circle, [3] dashed, [5] oval,",
        "[11:8] 1 pixel wide, [14:12] 2 = dashes of 4 pixels"))


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
        "text n = (offset - 0x114) / 16: top-left corner of the text,",
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
    global txt_sc
    txt_sc = 0
    if cam_w >= 256:
        txt_sc = 1
    text_set(T_NAME, 1, 1, TXT_ON | (name_len << 8), WHITE)
    text_set(T_CLOCK, cam_w - 1 - (48 << txt_sc), 1, TXT_ON | (12 << 8), YELLOW)
    text_word(T_FRAME, 0, 0x6D617266)                  # "fram"
    text_word(T_FRAME, 1, 0x756E2065)                  # "e nu"
    text_word(T_FRAME, 2, 0x7265626D)                  # "mber"
    text_word(T_FRAME, 3, 0x20)                        # " "
    text_set(T_FRAME, 1, cam_h - 1 - (6 << txt_sc), TXT_ON | TXT_FNUM | (13 << 8), WHITE)
    wreg(OVL + OVL_FNUM, 1, strings(                    # the first frame of the sequence is number 1
        "symbol_overlay FRAME_NUM",
        "BCD frame number shown by the frame-number text in the next",
        "frame: 1, then the overlay adds 1 at every frame start"))
