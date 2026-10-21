"""video_processor firmware: the NPU detector and a ByteTrack-type multi-object tracker (py_core v2).

The NPU (registers at NPU, golden model ip/ai/npu/model/npu_model.py) runs the compiled detector (YOLOv8s by default, 80 COCO
classes) on every frame its frame writer stores in DDR and leaves a list of detections there (16 bytes
each: x0 | x1 << 16, y0 | y1 << 16, class | score << 8, in frame pixels; score 0-255). Its program is
preloaded in DDR; a header at NPU_HDR gives the descriptor address, the network input size (width x
height) and that of a second, low-resolution pass for large objects (0: none; its letterbox in LB2_*,
set by npu_setup). On every tracker event (frame_counter channel 4: the NPU's results are ready) bt_event():
  1. reads the detections through the CPU's DDR window, keeps the classes selected (det_mask, by group);
  2. (non-maximum suppression and the foreground-first order are the NPU's: NMS operation) a backpack,
     umbrella, handbag, tie or suitcase inside a person is part of the person (suppressed);
  3. predicts every track (steady-state Kalman filter: position and size with velocity, alpha 3/4, beta 1/4
     for the position and 1/8 for the size: shifts and one multiply, no matrices);
  4. associates as ByteTrack (Zhang et al., ECCV 2022; thresholds of Ultralytics' bytetrack.yaml): tracked
     and lost tracks with the high-score detections (score 0.25+, IoU x score 0.2+), the tracks still
     unmatched with the low-score ones (0.1-0.25, IoU 0.5+), the tentative tracks with the rest of the high
     ones (IoU x score 0.3+); association is greedy by the highest value, a match across groups counting
     half (ByteTrack uses the Hungarian algorithm; greedy is its usual embedded stand-in);
  5. two tracks of a group overlapping by more than 0.4 for 3 frames in a row are one object (the
     detector's two boxes for it): the younger is dropped; a strong detection left over that overlaps a
     lost track revives it, one that overlaps a matched track (IoU 0.5+) is a duplicate and dropped;
     unmatched tentative tracks are dropped, unmatched tracked ones become lost (their velocity slowing
     by a quarter per frame) and are kept TRACK_BUFFER frames for re-identification; unmatched high
     detections (0.25+) start tentative tracks, confirmed by a second match; a track's class follows its
     detections by vote (VOTE_MAX), so an odd detection of another class does not change it;
  6. draws every confirmed track matched this frame or lost for at most COAST_SHOW frames (at its
     predicted position, while inside the frame and not over a matched track of its group: coast_shown): overlay object k = track k (32: two overlay banks), the group's symbol and
     colour (P person: white box with corners; G ground transport: red box with ticks; A aircraft: green
     triangle; O any other object: yellow box with corners) and its label (group letter and the lowest
     number free in the group) below it, at the box centre (the symbol's size scales with the frame:
     mark_half, overlay.symbol_scale).
State lives in the data RAM (RAM): tracks (16 words each), detections (8 words each), the IoU table.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

NPU_ID = 0x4E505538                # "NPU8"
NPU_MAGIC = 0x4E505538             # DDR header magic (npu_compiler.py HDR_MAGIC)
NPU_HDR = 0x1000                   # DDR: magic, descriptor address, input width, classes, input height, second pass w, h
FRAME_BUF = 0x00100000             # DDR: frame buffer (RGB888)
DET_BUF = 0x00800000               # DDR: detection list
N_CTRL = 0x10                      # NPU registers (ip/ai/npu/src/include/npu_regs.json)
N_DESC = 0x24
N_DET = 0x28
N_DETMAX = 0x2C
N_DETCNT = 0x30
N_FRAME = 0x34
N_STRIDE = 0x38
N_FSIZE = 0x3C
N_STEP = 0x40
N_OFS = 0x44
N_LBSIZE = 0x48
N_INV = 0x4C
N_CYC = 0x50
N_RUNS = 0x54
N_STEP2 = 0x58                     # the second letterbox (the low-resolution pass for large objects)
N_OFS2 = 0x5C
N_LBSIZE2 = 0x60
N_INV2 = 0x64
NT = 32                            # tracks (= overlay objects, two banks of 16)
ND = 64                            # detections read per frame
T_RAM = RAM                        # tracks: 16 words each
D_RAM = RAM + 0x1000               # detections: 16 words each (64 x 64 bytes)
I_RAM = RAM + 0x3000               # IoU table, track k x detection i (per mille; 32 x 64 words)
T_ST = 0                           # track words: state (0 free, 1 tentative, 2 tracked, 3 lost)
T_CLS = 4
T_LAB = 8                          # label word (overlay OBJ_LABEL)
T_HITS = 12
T_LOST = 16                        # frames since its last match
T_VOTE = 20                        # class votes: the track's class changes when they run out
T_CX = 24                          # centre x 16 (Q4 pixels), size x 16, velocities (Q4 per frame)
T_CY = 28
T_W = 32
T_H = 36
T_VX = 40
T_VY = 44
T_VW = 48
T_VH = 52
T_DET = 56                         # detection matched this frame (-1: none)
T_OVL = 60                         # frames in a row it overlaps an older track of its group (merge)
D_X0 = 0                           # detection words (bytes)
D_Y0 = 4
D_X1 = 8
D_Y1 = 12
D_CLS = 16
D_SC = 20
D_USED = 24
D_SUP = 28
D_GRP = 32                         # its overlay group (group(class))
HIGH = 64                          # ByteTrack thresholds on the 0-255 score (Ultralytics bytetrack.yaml):
LOW = 25                           # high 0.25, low 0.1 (the NPU's own threshold), a new track 0.25
NEW = 64
IOU_HIGH = 200                     # first stage: IoU x score (fuse_score), as match_thresh 0.8
IOU_LOW = 500
IOU_TENT = 300
TRACK_BUFFER = 30                  # frames a lost track is kept
COAST_SHOW = 5                     # frames a lost track is still drawn at its predicted position
COAST_COVER = 500                  # ... unless it and a matched track of its group overlap by this much of the
                                   # smaller box (per mille)
MERGE_IOU = 400                    # two tracks of a group overlapping this much (per mille) ...
MERGE_FRAMES = 3                   # ... for this many frames in a row are one object: the younger dropped
MERGE_COVER = 700                  # or overlapping by this much of the smaller box (per mille): a part of the
                                   # object, when that box is 1/4 of the other or more (any size: aircraft)
CONFIRM_HITS = 2
VOTE_MAX = 8
npu_mode = 0                       # 1: the NPU detector and this tracker drive the overlay
bt_n = 0                           # detections read this frame
bt_tracks = 0                      # tracks started in the sequence
lb_sw = 0                          # fit(): the picture's size in the network input
lb_sh = 0
COCO = strings(
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
    "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
    "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
    "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
    "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
    "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
    "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush")


def sread(a):
    """Signed word of the data RAM (mem32 reads it unsigned)."""
    v = mem32[a]
    if v & 0x80000000:
        v = v - 0x80000000 - 0x80000000
    return v


def group(c):
    """Overlay group of COCO class c: 0 person, 1 ground transport, 2 aircraft, 3 any other object."""
    if c == 0:
        return 0
    if c == 4:
        return 2
    if (c >= 1 and c <= 3) or (c >= 5 and c <= 8):
        return 1
    return 3


def group_on(g):
    """The camera's class selection (det_mask) by group: other objects with every class selected."""
    if g == 0:
        return det_mask & 3
    if g == 1:
        return det_mask & 12
    if g == 2:
        return det_mask & 16
    return det_mask == 31


def group_class(g):
    """The firmware class whose symbol style the group uses (camera registers 0x51-0x55)."""
    if g == 1:
        return C_CAR
    if g == 2:
        return C_AIR
    return C_PED


def group_colour(g):
    if g == 0:
        return WHITE
    if g == 1:
        return TRK_RED
    if g == 2:
        return TRK_GREEN
    return YELLOW


def group_letter(g):
    if g == 0:
        return 80                                      # "P"
    if g == 1:
        return 71                                      # "G"
    if g == 2:
        return 65                                      # "A"
    return 79                                          # "O"


def npu_present():
    """1 when the NPU answers and its program is in DDR."""
    return mem32[NPU] == NPU_ID and mem32[DDR_WIN + NPU_HDR] == NPU_MAGIC


def fit(nw, nh):
    """The frame's letterbox in an nw x nh network input (integer arithmetic, as the compiler's geometry()):
    its size into lb_sw, lb_sh."""
    global lb_sw, lb_sh
    if cam_w * nh >= cam_h * nw:
        lb_sw = nw
        lb_sh = (2 * cam_h * nw + cam_w) // (2 * cam_w)
    else:
        lb_sw = (2 * cam_w * nh + cam_h) // (2 * cam_h)
        lb_sh = nh


def npu_setup():
    """NPU for the sequence's frame size: frame writer, letterbox of each pass, detection list, automatic
    runs; every track free."""
    global bt_tracks
    nw = mem32[DDR_WIN + NPU_HDR + 8]                  # the network input, nw x nh
    nh = mem32[DDR_WIN + NPU_HDR + 16]
    if nh == 0:                                        # (a square program)
        nh = nw
    wreg(NPU + N_DESC, mem32[DDR_WIN + NPU_HDR + 4], strings(
        "npu DESC_ADDR", "first layer descriptor of the detector program in DDR",
        "(preloaded; header at DDR 0x1000)"))
    wreg(NPU + N_DET, DET_BUF, strings("npu DET_ADDR", "detection list in DDR (16 bytes each)", ""))
    wreg(NPU + N_DETMAX, ND, strings("npu DET_MAX", "at most 64 detections per frame", ""))
    wreg(NPU + N_FRAME, FRAME_BUF, strings("npu FRAME_ADDR", "frame buffer in DDR (RGB888)", ""))
    wreg(NPU + N_STRIDE, cam_w * 3, strings("npu FRAME_STRIDE", "bytes per frame buffer line: 3 x width", ""))
    wreg(NPU + N_FSIZE, (cam_h << 16) | cam_w, strings("npu FRAME_SIZE", "[15:0] width, [31:16] height", ""))
    fit(nw, nh)
    wreg(NPU + N_STEP, (cam_w << 16) // lb_sw, strings(
        "npu LB_STEP", "frame pixels per network input pixel, Q16", ""))
    wreg(NPU + N_OFS, (((nh - lb_sh) >> 1) << 16) | ((nw - lb_sw) >> 1), strings(
        "npu LB_OFFSET", "the picture centred in the nw x nh network input", ""))
    wreg(NPU + N_LBSIZE, (lb_sh << 16) | lb_sw, strings(
        "npu LB_SIZE", "the picture's size in the network input", ""))
    wreg(NPU + N_INV, ((cam_w << 16) + (lb_sw >> 1)) // lb_sw, strings(
        "npu LB_INV", "frame pixels per input pixel, Q16: boxes in frame pixels", ""))
    nw = mem32[DDR_WIN + NPU_HDR + 20]                 # the second, low-resolution pass (0: none)
    nh = mem32[DDR_WIN + NPU_HDR + 24]
    if nw and nh:
        fit(nw, nh)
        wreg(NPU + N_STEP2, (cam_w << 16) // lb_sw, strings(
            "npu LB2_STEP", "second pass (large objects, about 640 wide):", "frame pixels per input pixel, Q16"))
        wreg(NPU + N_OFS2, (((nh - lb_sh) >> 1) << 16) | ((nw - lb_sw) >> 1), strings(
            "npu LB2_OFFSET", "the picture centred in the second pass's input", ""))
        wreg(NPU + N_LBSIZE2, (lb_sh << 16) | lb_sw, strings(
            "npu LB2_SIZE", "the picture's size in the second pass's input", ""))
        wreg(NPU + N_INV2, ((cam_w << 16) + (lb_sw >> 1)) // lb_sw, strings(
            "npu LB2_INV", "frame pixels per second-pass input pixel, Q16", ""))
    wreg(NPU + N_CTRL, 7, strings(
        "npu CTRL", "[0] on, [1] a run on every frame, [2] frame writer on:",
        "the detector runs on every frame, results by tracker event"))
    k = 0
    while k < NT:
        mem32[T_RAM + (k << 6) + T_ST] = 0
        mem32[obj_addr(0, k) + OBJ_CTRL] = 0            # every overlay object off, no label
        mem32[obj_label(0, k)] = 0
        k += 1
    bt_tracks = 0


def iou(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1):
    """Intersection over union of two boxes (inclusive pixels), per mille."""
    ix = min2(ax1, bx1) - max2(ax0, bx0) + 1
    iy = min2(ay1, by1) - max2(ay0, by0) + 1
    if ix <= 0 or iy <= 0:
        return 0
    inter = ix * iy
    u = (ax1 - ax0 + 1) * (ay1 - ay0 + 1) + (bx1 - bx0 + 1) * (by1 - by0 + 1) - inter
    return (inter * 1000) // u


def cover(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1):
    """Intersection over the smaller box's area (inclusive pixels), per mille."""
    ix = min2(ax1, bx1) - max2(ax0, bx0) + 1
    iy = min2(ay1, by1) - max2(ay0, by0) + 1
    if ix <= 0 or iy <= 0:
        return 0
    return (ix * iy * 1000) // min2((ax1 - ax0 + 1) * (ay1 - ay0 + 1), (bx1 - bx0 + 1) * (by1 - by0 + 1))


def min2(a, b):
    if a < b:
        return a
    return b


def max2(a, b):
    if a > b:
        return a
    return b


def read_dets():
    """The NPU's detections of the selected groups into the data RAM; their count."""
    n = mem32[NPU + N_DETCNT]
    if n > ND:
        n = ND
    m = 0
    i = 0
    while i < n:
        s = DDR_WIN + DET_BUF + (i << 4)
        w2 = mem32[s + 8]
        c = w2 & 255
        if group_on(group(c)):
            d = D_RAM + (m << 6)
            w = mem32[s]
            mem32[d + D_X0] = w & 0xFFFF
            mem32[d + D_X1] = w >> 16
            w = mem32[s + 4]
            mem32[d + D_Y0] = w & 0xFFFF
            mem32[d + D_Y1] = w >> 16
            mem32[d + D_CLS] = c
            mem32[d + D_GRP] = group(c)
            mem32[d + D_SC] = (w2 >> 8) & 255
            mem32[d + D_USED] = 0
            mem32[d + D_SUP] = 0
            m += 1
        i += 1
    return m


def drop_accessories():
    """A backpack, umbrella, handbag, tie or suitcase (COCO 24-28) whose centre lies in a person's box is
    part of that person: suppressed (not a target of its own)."""
    i = 0
    while i < bt_n:
        d = D_RAM + (i << 6)
        c = mem32[d + D_CLS]
        if c >= 24 and c <= 28 and not mem32[d + D_SUP]:
            cx = (mem32[d + D_X0] + mem32[d + D_X1]) >> 1
            cy = (mem32[d + D_Y0] + mem32[d + D_Y1]) >> 1
            j = 0
            while j < bt_n:
                e = D_RAM + (j << 6)
                if (mem32[e + D_CLS] == 0 and not mem32[e + D_SUP] and cx >= mem32[e + D_X0]
                        and cx <= mem32[e + D_X1] and cy >= mem32[e + D_Y0] and cy <= mem32[e + D_Y1]):
                    mem32[d + D_SUP] = 1
                j += 1
        i += 1


def predict():
    """Every live track moved by its velocity; its IoU with every detection into I_RAM; no match yet."""
    k = 0
    while k < NT:
        t = T_RAM + (k << 6)
        mem32[t + T_DET] = -1
        if mem32[t + T_ST]:
            cx = sread(t + T_CX) + sread(t + T_VX)
            cy = sread(t + T_CY) + sread(t + T_VY)
            w = sread(t + T_W) + sread(t + T_VW)
            h = sread(t + T_H) + sread(t + T_VH)
            if w < 16:
                w = 16
            if h < 16:
                h = 16
            mem32[t + T_CX] = cx
            mem32[t + T_CY] = cy
            mem32[t + T_W] = w
            mem32[t + T_H] = h
            x0 = (cx - (w >> 1)) >> 4
            x1 = (cx + (w >> 1)) >> 4
            y0 = (cy - (h >> 1)) >> 4
            y1 = (cy + (h >> 1)) >> 4
            i = 0
            while i < bt_n:
                d = D_RAM + (i << 6)
                mem32[I_RAM + (((k << 6) + i) << 2)] = iou(x0, y0, x1, y1, mem32[d + D_X0], mem32[d + D_Y0],
                                                          mem32[d + D_X1], mem32[d + D_Y1])
                i += 1
        k += 1


def associate(sa, sb, smin, smax, imin, fuse):
    """Greedy association: tracks in state sa or sb without a match, detections unused, not suppressed,
    with a score in smin .. smax - 1, of any class (as Ultralytics' ByteTrack; the track's class follows
    its detections by vote): the pair with the highest IoU (fuse: IoU x score, ByteTrack's fuse_score)
    of imin or more first, until none is left."""
    while True:
        best = imin - 1
        bk = -1
        bi = -1
        k = 0
        while k < NT:
            t = T_RAM + (k << 6)
            st = mem32[t + T_ST]
            if (st == sa or st == sb) and sread(t + T_DET) < 0:
                tg = group(mem32[t + T_CLS])
                i = 0
                while i < bt_n:
                    d = D_RAM + (i << 6)
                    v = mem32[I_RAM + (((k << 6) + i) << 2)]
                    s = mem32[d + D_SC]
                    if fuse:
                        v = (v * s) // 255
                    if mem32[d + D_GRP] != tg:                 # another group (a person as a car):
                        v = v >> 1                             # half the overlap
                    if v > best and not mem32[d + D_USED] and not mem32[d + D_SUP]:
                        if s >= smin and s < smax:
                            best = v
                            bk = k
                            bi = i
                    i += 1
            k += 1
        if bk < 0:
            return
        mem32[T_RAM + (bk << 6) + T_DET] = bi
        mem32[D_RAM + (bi << 6) + D_USED] = 1


def update(k, i):
    """Track k with detection i: alpha-beta (steady-state Kalman) update of centre, size and velocities."""
    t = T_RAM + (k << 6)
    d = D_RAM + (i << 6)
    zx = (mem32[d + D_X0] + mem32[d + D_X1]) << 3      # Q4 centre
    zy = (mem32[d + D_Y0] + mem32[d + D_Y1]) << 3
    zw = (mem32[d + D_X1] - mem32[d + D_X0] + 1) << 4
    zh = (mem32[d + D_Y1] - mem32[d + D_Y0] + 1) << 4
    r = zx - sread(t + T_CX)
    mem32[t + T_CX] = sread(t + T_CX) + ((3 * r) >> 2)
    mem32[t + T_VX] = sread(t + T_VX) + (r >> 2)
    r = zy - sread(t + T_CY)
    mem32[t + T_CY] = sread(t + T_CY) + ((3 * r) >> 2)
    mem32[t + T_VY] = sread(t + T_VY) + (r >> 2)
    r = zw - sread(t + T_W)
    mem32[t + T_W] = sread(t + T_W) + ((3 * r) >> 2)
    mem32[t + T_VW] = sread(t + T_VW) + (r >> 3)
    r = zh - sread(t + T_H)
    mem32[t + T_H] = sread(t + T_H) + ((3 * r) >> 2)
    mem32[t + T_VH] = sread(t + T_VH) + (r >> 3)
    mem32[t + T_HITS] = mem32[t + T_HITS] + 1
    mem32[t + T_LOST] = 0
    c = mem32[d + D_CLS]                               # the class: a vote, so one odd detection (a car
    tc = mem32[t + T_CLS]                              # seen as something else) does not change it
    if c == tc:
        if mem32[t + T_VOTE] < VOTE_MAX:
            mem32[t + T_VOTE] = mem32[t + T_VOTE] + 1
    else:
        mem32[t + T_VOTE] = mem32[t + T_VOTE] - 1
        if mem32[t + T_VOTE] == 0:
            mem32[t + T_CLS] = c
            mem32[t + T_VOTE] = 1
            if group(c) != group(tc):                  # another group: labelled again
                mem32[t + T_LAB] = 0


def start(k, i):
    """A tentative track k at detection i, at rest."""
    t = T_RAM + (k << 6)
    d = D_RAM + (i << 6)
    mem32[t + T_ST] = 1
    mem32[t + T_CLS] = mem32[d + D_CLS]
    mem32[t + T_LAB] = 0
    mem32[t + T_HITS] = 1
    mem32[t + T_LOST] = 0
    mem32[t + T_VOTE] = 1
    mem32[t + T_OVL] = 0
    mem32[t + T_CX] = (mem32[d + D_X0] + mem32[d + D_X1]) << 3
    mem32[t + T_CY] = (mem32[d + D_Y0] + mem32[d + D_Y1]) << 3
    mem32[t + T_W] = (mem32[d + D_X1] - mem32[d + D_X0] + 1) << 4
    mem32[t + T_H] = (mem32[d + D_Y1] - mem32[d + D_Y0] + 1) << 4
    mem32[t + T_VX] = 0
    mem32[t + T_VY] = 0
    mem32[t + T_VW] = 0
    mem32[t + T_VH] = 0
    mem32[t + T_DET] = i


def label_num(lab):
    """The number of a label word (1-32; 0: none): one digit, or tens then units."""
    if not lab:
        return 0
    if (lab >> 16) & 255:
        return 10 * (((lab >> 8) & 255) - 48) + ((lab >> 16) & 255) - 48
    return ((lab >> 8) & 255) - 48


def label(k):
    """Label word of track k: its group letter and the lowest number no other confirmed track of the
    group has (1-32: one or two digits; the used numbers kept as bits 1-31 of one word)."""
    g = group(mem32[T_RAM + (k << 6) + T_CLS])
    used = 0
    j = 0
    while j < NT:
        t = T_RAM + (j << 6)
        if j != k and mem32[t + T_ST] >= 2 and group(mem32[t + T_CLS]) == g:
            u = label_num(mem32[t + T_LAB])
            if u > 0 and u < 32:
                used = used | (1 << u)
        j += 1
    n = 1
    while n < 32 and used & (1 << n):
        n += 1
    if n < 10:
        return group_letter(g) | ((48 + n) << 8)
    return group_letter(g) | ((48 + n // 10) << 8) | ((48 + n % 10) << 16)   # tens, units


def confirmed():
    """Confirmed tracks (tracked or lost)."""
    n = 0
    k = 0
    while k < NT:
        if mem32[T_RAM + (k << 6) + T_ST] >= 2:
            n += 1
        k += 1
    return n


def bt_event(n):
    """One frame: detections, NMS, prediction, ByteTrack association, track life cycle, overlay, the
    transcript's part of the line."""
    global bt_n, bt_tracks
    bt_n = read_dets()                                 # already NMS'd by the NPU, largest first
    drop_accessories()
    predict()
    associate(2, 3, HIGH, 256, IOU_HIGH, 1)            # 1st: tracked / lost with the high detections
    associate(2, 2, LOW, HIGH, IOU_LOW, 0)             # 2nd: tracked still unmatched with the low ones
    associate(1, 1, HIGH, 256, IOU_TENT, 1)            # tentative with the high ones left
    k = 0
    while k < NT:                                      # life cycle
        t = T_RAM + (k << 6)
        st = mem32[t + T_ST]
        i = sread(t + T_DET)
        if st:
            if i >= 0:
                update(k, i)
                if st == 1 and mem32[t + T_HITS] >= CONFIRM_HITS and confirmed() < max_targets:
                    mem32[t + T_ST] = 2
                    mem32[t + T_LAB] = label(k)
                    bt_tracks += 1
                elif st == 3:
                    mem32[t + T_ST] = 2
                if mem32[t + T_ST] == 2 and not mem32[t + T_LAB]:   # its class changed group
                    mem32[t + T_LAB] = label(k)
            elif st == 1:
                mem32[t + T_ST] = 0                    # a tentative track missed: dropped
            else:
                mem32[t + T_ST] = 3
                mem32[t + T_LOST] = mem32[t + T_LOST] + 1
                mem32[t + T_VX] = (3 * sread(t + T_VX)) // 4   # lost: it slows down (a stopped car or
                mem32[t + T_VY] = (3 * sread(t + T_VY)) // 4   # person is found again where it was)
                mem32[t + T_VW] = 0
                mem32[t + T_VH] = 0
                if mem32[t + T_LOST] > TRACK_BUFFER:
                    mem32[t + T_ST] = 0
                    mem32[t + T_LAB] = 0
        k += 1
    merge()
    i = 0
    while i < bt_n:                                    # the strong detections left, largest first (the
        d = D_RAM + (i << 6)                           # NPU's order): new tentative tracks
        if not mem32[d + D_USED] and not mem32[d + D_SUP] and mem32[d + D_SC] >= NEW:
            k = overlap(i)
            if k >= 0:                                 # a lost track of this object: found again
                if mem32[T_RAM + (k << 6) + T_ST] == 3:
                    update(k, i)
                    mem32[T_RAM + (k << 6) + T_ST] = 2
                    mem32[T_RAM + (k << 6) + T_DET] = i
                mem32[d + D_USED] = 1                  # (or a duplicate of a tracked one: dropped)
            else:
                k = free_slot(i)
                if k >= 0:
                    start(k, i)
                    mem32[d + D_USED] = 1
        i += 1
    bt_draw()


def merge():
    """Duplicate tracks of one object (the detector's two boxes for it), two tracks of a group, both
    tracked, for MERGE_FRAMES frames in a row: overlapping by more than MERGE_IOU, the younger (fewer hits;
    on a tie the higher slot) is dropped; or the smaller overlapping by more than MERGE_COVER of its box
    and a quarter of the other's area or more (a part box: a person cut by the frame's edge and their upper
    body; aircraft any size: the parts of a large aircraft), the smaller is dropped. A distant person or
    car behind a near one is usually under a quarter of its size and stays."""
    k = 0
    while k < NT:
        t = T_RAM + (k << 6)
        seen = 0
        if mem32[t + T_ST] == 2:
            g = group(mem32[t + T_CLS])
            hk = mem32[t + T_HITS]
            ax0 = (sread(t + T_CX) - (sread(t + T_W) >> 1)) >> 4
            ax1 = (sread(t + T_CX) + (sread(t + T_W) >> 1)) >> 4
            ay0 = (sread(t + T_CY) - (sread(t + T_H) >> 1)) >> 4
            ay1 = (sread(t + T_CY) + (sread(t + T_H) >> 1)) >> 4
            ak = (ax1 - ax0 + 1) * (ay1 - ay0 + 1)
            j = 0
            while j < NT and not seen:
                b = T_RAM + (j << 6)
                if j != k and mem32[b + T_ST] == 2 and group(mem32[b + T_CLS]) == g:
                    older = mem32[b + T_HITS] > hk or (mem32[b + T_HITS] == hk and j < k)
                    bw = sread(b + T_W) >> 1
                    bh = sread(b + T_H) >> 1
                    bx0 = (sread(b + T_CX) - bw) >> 4
                    by0 = (sread(b + T_CY) - bh) >> 4
                    bx1 = (sread(b + T_CX) + bw) >> 4
                    by1 = (sread(b + T_CY) + bh) >> 4
                    aj = (bx1 - bx0 + 1) * (by1 - by0 + 1)
                    if iou(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1) > MERGE_IOU:
                        if older:
                            seen = 1
                    elif (ak < aj or (ak == aj and older)) and (g == 2 or (ak << 2) >= aj):
                        if cover(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1) > MERGE_COVER:
                            seen = 1                  # k is a part of j's object
                j += 1
        if seen:
            mem32[t + T_OVL] = mem32[t + T_OVL] + 1
            if mem32[t + T_OVL] >= MERGE_FRAMES:      # one object: this track goes
                mem32[t + T_ST] = 0
                mem32[t + T_LAB] = 0
                mem32[obj_addr(0, k) + OBJ_CTRL] = 0
        else:
            mem32[t + T_OVL] = 0
        k += 1


def overlap(i):
    """A track that detection i belongs to: a track matched this frame that it overlaps by more than half
    (a duplicate), or a lost one it overlaps (IoU 0.1+, the best); -1 when none."""
    best = 99
    bk = -1
    k = 0
    while k < NT:
        t = T_RAM + (k << 6)
        st = mem32[t + T_ST]
        v = mem32[I_RAM + (((k << 6) + i) << 2)]
        if st == 2 and sread(t + T_DET) >= 0 and sread(t + T_DET) != i and v > 500:
            return k
        if st == 3 and v > best:
            best = v
            bk = k
        k += 1
    return bk


def free_slot(i):
    """A free track for detection i; when none is free (or the most targets are confirmed), the smallest
    track if detection i is at least twice its area (foreground before background); else -1."""
    d = D_RAM + (i << 6)
    area = (mem32[d + D_X1] - mem32[d + D_X0] + 1) * (mem32[d + D_Y1] - mem32[d + D_Y0] + 1) * 256
    small = -1
    sa = 0
    k = 0
    while k < NT:
        t = T_RAM + (k << 6)
        if mem32[t + T_ST] == 0:
            if confirmed() < max_targets:
                return k
        else:
            a = sread(t + T_W) * sread(t + T_H)
            if small < 0 or a < sa:
                small = k
                sa = a
        k += 1
    if small >= 0 and area >= (sa << 1):               # Q4 x Q4 areas: x 256 on both sides
        mem32[obj_addr(0, small) + OBJ_CTRL] = 0
        mem32[T_RAM + (small << 6) + T_ST] = 0
        mem32[T_RAM + (small << 6) + T_LAB] = 0
        return small
    return -1


def coast_shown(k):
    """A lost track k is drawn while coasting: its predicted centre inside the frame (not an object that
    has left: its symbol would be clamped onto whatever is at the edge) and not overlapping a track of its
    group matched this frame by more than COAST_COVER of the smaller box (the same object, or one hidden
    behind it)."""
    t = T_RAM + (k << 6)
    cx = sread(t + T_CX) >> 4
    cy = sread(t + T_CY) >> 4
    if cx < 0 or cy < 0 or cx >= cam_w or cy >= cam_h:
        return 0
    g = group(mem32[t + T_CLS])
    ax0 = (sread(t + T_CX) - (sread(t + T_W) >> 1)) >> 4
    ax1 = (sread(t + T_CX) + (sread(t + T_W) >> 1)) >> 4
    ay0 = (sread(t + T_CY) - (sread(t + T_H) >> 1)) >> 4
    ay1 = (sread(t + T_CY) + (sread(t + T_H) >> 1)) >> 4
    j = 0
    while j < NT:
        b = T_RAM + (j << 6)
        if mem32[b + T_ST] == 2 and sread(b + T_DET) >= 0 and group(mem32[b + T_CLS]) == g:
            bw = sread(b + T_W) >> 1
            bh = sread(b + T_H) >> 1
            if cover(ax0, ay0, ax1, ay1, (sread(b + T_CX) - bw) >> 4, (sread(b + T_CY) - bh) >> 4,
                     (sread(b + T_CX) + bw) >> 4, (sread(b + T_CY) + bh) >> 4) > COAST_COVER:
                return 0
        j += 1
    return 1


def bt_draw():
    """Overlay object k for track k (confirmed: matched this frame or coasting at most COAST_SHOW frames),
    its part of the transcript line."""
    puts(" NPU ")
    dec(bt_n)
    puts(" detections")
    k = 0
    while k < NT:
        t = T_RAM + (k << 6)
        o = obj_addr(0, k)
        st = mem32[t + T_ST]
        if (st == 2 and sread(t + T_DET) >= 0) or (st == 3 and mem32[t + T_LOST] <= COAST_SHOW
                                                    and coast_shown(k)):
            c = mem32[t + T_CLS]
            g = group(c)
            cx = sread(t + T_CX) >> 4
            cy = sread(t + T_CY) >> 4
            x0 = clip(cx - mark_half, cam_w - 1 - (mark_half << 1))
            y0 = clip(cy - mark_half, cam_h - 1 - (mark_half << 1))
            mem32[o + OBJ_X] = ((x0 + (mark_half << 1)) << 16) | x0
            mem32[o + OBJ_Y] = ((y0 + (mark_half << 1)) << 16) | y0
            mem32[o + OBJ_COLOR] = group_colour(g)
            mem32[o + OBJ_CTRL] = class_shape(group_class(g))
            mem32[obj_label(0, k)] = mem32[t + T_LAB]
            putw(0x203B)                               # "; "
            putw(mem32[t + T_LAB])
            putc(32)
            puts(COCO + c)
            putw(0x207820)                             # " x "
            range_out(x0, x0 + (mark_half << 1))
            putw(W_Y)
            range_out(y0, y0 + (mark_half << 1))
        else:
            mem32[o + OBJ_CTRL] = 0
        k += 1
