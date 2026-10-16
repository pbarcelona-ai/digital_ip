"""video_processor firmware: the object detectors and the multi-target tracking state machine.

NTRK object_tracker detectors, one per object class (video_processor_map_pkg: detector c at
TRK + c * TRK_STRIDE). The classes to detect (det_mask, bit c), the box style of each and the most
targets tracked at any time (max_targets) come from the camera's control registers 0x50-0x55
(camera.py camera_detect). Each detector finds the pixels that look like its class (detect_setup):
  0 pedestrian  luma below 80 (a dark figure on a light scene), runs of 2+ pixels
  1 face        skin tone: Y 50-235, Cb 77-127, Cr 135-175, saturation 12+, runs 3 .. W/6
  2 automobile  saturated paint: Y 30-235, saturation 40+, runs W/16 .. W/3
  3 vehicle     the same paint in runs wider than W/3 (bus, truck, tram)
(W = frame width; a run is judged by its whole length) and groups them into up to NBLOB separate
objects per frame (blobs: BLOB_X / BLOB_Y / BLOB_N; specks smaller than the class's least size are
dropped by the hardware, BLOB_CFG.KEEP). The CPU checks the shape of each blob (class_ok: enough
pixels; a pedestrian at least as tall as wide and at most a quarter of the frame wide; a face about
as tall as it is wide; vehicles wider than tall; a face or a car at most half the frame wide). This
is a feature (colour, size, shape) detector, not a trained classifier. Each class has its own
detector, so a person inside a vehicle (a driver's face behind the windscreen) is found by the face
detector whatever the vehicle detectors find around it.

Tracking, per class: up to NTR targets (tracks), each SEARCH (free) -> TRACK (matched to a blob)
-> COAST (missed: the box keeps moving with the velocity) -> back to free after TRK_LOST misses in
a row. Every frame each live track takes the nearest unused blob of its class within its gate
(box width + height + TRK_GATE around its predicted centre); blobs left over start new tracks while
fewer than max_targets targets (all classes together) are tracked. A track's state lives in its
detector's SCRATCH words (TW words per track, sc_get / sc_set), so one set of functions serves
every class and track. Centres and velocities are kept x 2 (x0 + x1); the box size grows at once
but shrinks by a quarter of the difference per frame, so everything is adds and shifts (py_core has
no multiply or divide). pred_lo / pred_hi give the predicted box for the next frame.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

TRK_LEVEL = 80                     # pedestrian: luma below this (dark figure, light scene)
TRK_MIN_RUN = 2                    # horizontal runs of at least 2 target pixels (single-pixel noise ignored)
TRK_MIN_PIX = 40                   # pedestrian pixels for a detection
FACE_MIN_PIX = 24
CAR_MIN_PIX = 60
VEH_MIN_PIX = 120
TRK_LOST = 4                       # frames missed before the track is given up
TRK_GATE = 24                      # a blob farther than box width + height + 24 (x 2 units) is another target
NTR = 3                            # tracks per class (overlay object c * NTR + k)
NOBJ_MAX = 12                      # overlay objects: NTRK classes x NTR tracks
TW = 9                             # SCRATCH words per track
S_SEARCH = 0                       # free: no target
S_TRACK = 1
S_COAST = 2
S_LOST = 3                         # returned once by track_step: the target was just given up
SC_STATE = 0                       # SCRATCH words of a track (+ k * TW)
SC_MISS = 1                        # frames missed in a row
SC_CX = 2                          # box centre x 2 (x0 + x1), y 2
SC_CY = 3
SC_VX = 4                          # centre velocity, x 2 pixels per frame (smoothed), + V_BIAS
SC_VY = 5
SC_W = 6                           # box width, height (x1 - x0, y1 - y0)
SC_H = 7
SC_FOUND = 8                       # frames this track found its target
SC_CLASS_FOUND = 27                # the class: frames with at least one target found
V_BIAS = 0x10000                   # velocities are stored + V_BIAS (registers hold unsigned words)
det_mask = 1                       # classes detected (bit c)
det_style = 0                      # box style of class c in bits 3c+2..3c (overlay.py)
max_targets = NOBJ_MAX             # most targets tracked at any time, all classes together
trk_live = 0                       # targets tracked now (all classes)
trk_frames = 0                     # tracker frames processed
trk_found = 0                      # frames with at least one target found


def det_base(c):
    """Address of class c's detector: TRK + c * TRK_STRIDE."""
    b = TRK
    while c > 0:
        b += TRK_STRIDE
        c -= 1
    return b


def sc_get(t, k):
    return mem32[t + TRK_SCRATCH + (k << 2)]


def sc_set(t, k, v):
    mem32[t + TRK_SCRATCH + (k << 2)] = v


def track_word(k):
    """First SCRATCH word of track k (k * TW)."""
    b = 0
    while k > 0:
        b += TW
        k -= 1
    return b


def class_name(c):
    if c == C_PED:
        puts("pedestrian")
    elif c == C_FACE:
        puts("face")
    elif c == C_CAR:
        puts("automobile")
    else:
        puts("vehicle")


def class_min(c):
    """Fewest pixels of a target of class c (also the blobs' BLOB_CFG.KEEP)."""
    if c == C_PED:
        return TRK_MIN_PIX
    if c == C_FACE:
        return FACE_MIN_PIX
    if c == C_CAR:
        return CAR_MIN_PIX
    return VEH_MIN_PIX


def detect_setup(c):
    """Detector of class c: its look, the frame size, the whole frame searched, blobs, every track
    free."""
    t = det_base(c)
    wreg(t + TRK_SIZE, (cam_h << 16) | cam_w, strings(
        "object_tracker FRAME_SIZE (this class's detector)",
        "[15:0] width, [31:16] height: the detector's pixel and line",
        "counters wrap at this size (box coordinates in frame pixels)"))
    if c == C_PED:
        wreg(t + TRK_THRESH, TRK_LEVEL, strings(
            "object_tracker THRESH (pedestrian)",
            "[7:0] luma threshold 80: pixels with luma (R + 2G + B) / 4",
            "below 80 are target pixels (dark pedestrian on a light scene)"))
        wreg(t + TRK_RUN, ((cam_w >> 2) << 16) | TRK_MIN_RUN, strings(
            "object_tracker RUN (pedestrian)",
            "runs of 2 .. width / 4 pixels: a figure, not a speck or a",
            "whole dark band of the scene"))
        wreg(t + TRK_CTRL, 3 | (FEAT_OR << 12), strings(
            "object_tracker CTRL (pedestrian)",
            "[0] on, [1] dark target (below THRESH), [13:12] 1: dark OR",
            "moving (feature_detect motion bit): a walker in any clothes"))
    elif c == C_FACE:
        wreg(t + TRK_Y_RANGE, (235 << 8) | 50, strings(
            "object_tracker Y_RANGE (face)",
            "luma 50-235: skin from shadow to highlight, not black or",
            "burnt-out white"))
        wreg(t + TRK_CB_RANGE, (127 << 8) | 77, strings(
            "object_tracker CB_RANGE (face)",
            "Cb 77-127: skin tone has less blue than grey (every", "complexion falls in this band)"))
        wreg(t + TRK_CR_RANGE, (175 << 8) | 135, strings(
            "object_tracker CR_RANGE (face)",
            "Cr 135-175: skin tone has more red than grey, less than a",
            "saturated red"))
        wreg(t + TRK_SAT_MIN, 12, strings(
            "object_tracker SAT_MIN (face)",
            "saturation |Cb - 128| + |Cr - 128| of 12 or more: grey and",
            "white surfaces with a slight tint are not skin"))
        wreg(t + TRK_RUN, (div(cam_w, 6) << 16) | 3, strings(
            "object_tracker RUN (face)",
            "runs of 3 .. width / 6 skin pixels: a face, not a speck or a",
            "large skin-coloured wall"))
        wreg(t + TRK_CTRL, 5, strings(
            "object_tracker CTRL (face)",
            "[0] measuring on, [2] colour mode: Y, Cb, Cr in their ranges",
            "and saturation >= SAT_MIN make a target pixel"))
    else:
        wreg(t + TRK_Y_RANGE, (235 << 8) | 30, strings(
            "object_tracker Y_RANGE (automobile / vehicle)",
            "luma 30-235: painted bodywork, not black tyres or glare", ""))
        wreg(t + TRK_SAT_MIN, 40, strings(
            "object_tracker SAT_MIN (automobile / vehicle)",
            "saturation |Cb - 128| + |Cr - 128| of 40 or more: coloured",
            "paint stands out from the grey road and buildings"))
        ctl = 5 | (FEAT_OR << 12)                      # paint OR moving
        if c == C_CAR:
            wreg(t + TRK_RUN, (div(cam_w, 3) << 16) | (cam_w >> 4), strings(
                "object_tracker RUN (automobile)",
                "runs of width / 16 .. width / 3 pixels (whole run length):",
                "a car's body, not a sign or a bus passing behind it"))
        else:
            wreg(t + TRK_RUN, div(cam_w, 3) + 1, strings(
                "object_tracker RUN (vehicle)",
                "runs wider than width / 3 pixels: a bus, truck or tram, far",
                "longer than a car"))
            wreg(t + TRK_RUN_B, cam_w >> 4, strings(
                "object_tracker RUN_B (vehicle: edges)",
                "edge runs of width / 16 or more: an object outlined by edges",
                "on a smooth background (a plane on the sky)"))
            ctl = ctl | TERM_B
        wreg(t + TRK_CTRL, ctl, strings(
            "object_tracker CTRL (automobile / vehicle)",
            "[0] on, [2] colour mode, [13:12] 1: painted OR moving (white,",
            "grey, black cars too), [14] vehicle: + edge term B"))
    g = (3 << 8) | 2                                   # a figure's head, body and legs: one object
    if c == C_FACE:
        g = (1 << 8) | 1
    if c >= C_CAR:                                     # a vehicle's roof and body, apart at its windows
        g = (12 << 8) | 2
    wreg(t + TRK_BLOB_CFG, (class_min(c) << 16) | g, strings(
        "object_tracker BLOB_CFG",
        "[7:0] GAP columns, [15:8] GAP_Y lines (vehicles 12: roof and",
        "body), [31:16] KEEP: objects smaller than the class dropped"))
    search_whole_frame(t)
    k = 0
    while k < NTR:
        track_free(t, track_word(k))
        k += 1
    sc_set(t, SC_CLASS_FOUND, 0)


def track_free(t, b):
    sc_set(t, b + SC_STATE, S_SEARCH)
    sc_set(t, b + SC_MISS, 0)
    sc_set(t, b + SC_FOUND, 0)
    sc_set(t, b + SC_VX, V_BIAS)
    sc_set(t, b + SC_VY, V_BIAS)


def tracker_setup():
    """Every selected class's detector set up (the others off), no target tracked."""
    global trk_live
    c = 0
    while c < NTRK:
        if det_mask & (1 << c):
            detect_setup(c)
        else:
            mem32[det_base(c) + TRK_CTRL] = 0
        c += 1
    trk_live = 0


def mul(a, b):
    """a * b for a, b >= 0 by shift and add (py_core has no multiply)."""
    r = 0
    while b:
        if b & 1:
            r += a
        a = a << 1
        b = b >> 1
    return r


def class_ok(c, n, x0, y0, x1, y1):
    """Enough pixels and the shape of class c: a solid object (pixels at least 1/3 of the box, 1/4 for
    vehicles) that is not the scene itself (at most 3/4 of the frame wide and half its height,
    touching at most one frame border: a textured scene or a moving camera gives one huge blob)."""
    w = x1 - x0 + 1
    h = y1 - y0 + 1
    if n < class_min(c):
        return 0
    a = mul(w, h)
    if c == C_VEH:
        if (n << 2) < a:
            return 0
    elif (n << 1) + n < a:
        return 0
    b = 0
    if x0 == 0:
        b += 1
    if x1 >= cam_w - 1:
        b += 1
    if y0 == 0:
        b += 1
    if y1 >= cam_h - 1:
        b += 1
    if b >= 2 or (w << 2) > (cam_w << 1) + cam_w or (h << 1) > cam_h:
        return 0
    if c == C_PED:                                     # a standing figure: at least as tall as wide
        return h >= w and w <= (cam_w >> 2)
    if w > (cam_w >> 1):                               # a face or a car: at most half the frame wide
        if c != C_VEH:
            return 0
    if c == C_FACE:                                    # 3/4 to 2 times as tall as wide, small
        return (h << 2) >= (w << 1) + w and h <= (w << 1) and w <= (cam_w >> 3)
    if c == C_CAR:                                     # wider than tall, at least width / 10
        return w >= h and w >= div(cam_w, 10)
    return w >= (h << 1)                               # a bus, tram or plane: long and low


def in_target(c, x, y):
    """True when (x, y) lies in the predicted box of a target of class c."""
    t = det_base(c)
    k = 0
    while k < NTR:
        b = track_word(k)
        if sc_get(t, b + SC_STATE) != S_SEARCH:
            cx = sc_get(t, b + SC_CX) + sc_get(t, b + SC_VX) - V_BIAS
            w = sc_get(t, b + SC_W)
            if (x << 1) >= cx - w and (x << 1) <= cx + w:
                cy = sc_get(t, b + SC_CY) + sc_get(t, b + SC_VY) - V_BIAS
                h = sc_get(t, b + SC_H)
                if (y << 1) >= cy - h and (y << 1) <= cy + h:
                    return 1
        k += 1
    return 0


def blob_ok(c, t, i):
    """True when blob i of detector t has the shape of class c."""
    n = mem32[t + TRK_BLOB_N + (i << 2)]
    if n == 0:
        return 0
    x = mem32[t + TRK_BLOB_X + (i << 2)]
    y = mem32[t + TRK_BLOB_Y + (i << 2)]
    if not class_ok(c, n, x & 0xFFFF, y & 0xFFFF, x >> 16, y >> 16):
        return 0
    cx = ((x & 0xFFFF) + (x >> 16)) >> 1
    cy = ((y & 0xFFFF) + (y >> 16)) >> 1
    if c >= C_CAR:                                     # a moving pedestrian is not a car
        return not in_target(C_PED, cx, cy)
    if c == C_PED:                                     # nor a moving car's or bus's end a pedestrian
        if in_target(C_CAR, cx, cy):
            return 0
        return not in_target(C_VEH, cx, cy)
    return 1


def absv(v):
    if v < 0:
        return 0 - v
    return v


def smooth_size(size, measured, st):
    """Grow to the measured size at once, shrink by a quarter of the difference."""
    if st == S_SEARCH or measured > size:
        return measured
    return size - ((size - measured) >> 2)


def track_step(t, b, i):
    """One frame of the track at SCRATCH word b of detector t (i: the blob of its target, -1 when
    missed): the new state, read from and saved to the SCRATCH words.

    An alpha-beta tracker (Kalata, IEEE Trans. AES 1984) with alpha = 1 and beta = 1/2: the centre
    takes the measured blob centre (no position smoothing: the blob box is already a clean
    measurement), the velocity moves half way to the measured displacement, v = (v + (z - x)) / 2;
    a missed target coasts with its velocity until TRK_LOST misses. Association (nearest_blob) is
    gated greedy nearest neighbour in track order, a cheap stand-in for global nearest neighbour
    (Bar-Shalom & Fortmann 1988) that is enough for the few, mostly separated targets per class."""
    ok = i >= 0
    if ok:
        x0 = mem32[t + TRK_BLOB_X + (i << 2)]
        x1 = x0 >> 16
        x0 = x0 & 0xFFFF
        y0 = mem32[t + TRK_BLOB_Y + (i << 2)]
        y1 = y0 >> 16
        y0 = y0 & 0xFFFF
    st = sc_get(t, b + SC_STATE)
    miss = sc_get(t, b + SC_MISS)
    cx = sc_get(t, b + SC_CX)
    cy = sc_get(t, b + SC_CY)
    vx = sc_get(t, b + SC_VX) - V_BIAS
    vy = sc_get(t, b + SC_VY) - V_BIAS
    r = st
    if ok:                                             # found: velocity from the centre's move
        sc_set(t, b + SC_FOUND, sc_get(t, b + SC_FOUND) + 1)
        if st == S_SEARCH:
            vx = 0
            vy = 0
        else:
            vx = (vx + x0 + x1 - cx) >> 1
            vy = (vy + y0 + y1 - cy) >> 1
        sc_set(t, b + SC_W, smooth_size(sc_get(t, b + SC_W), x1 - x0, st))
        sc_set(t, b + SC_H, smooth_size(sc_get(t, b + SC_H), y1 - y0, st))
        cx = x0 + x1
        cy = y0 + y1
        st = S_TRACK
        miss = 0
        r = st
    elif st != S_SEARCH:                               # missed: coast with the velocity
        miss += 1
        cx = cx + vx
        cy = cy + vy
        st = S_COAST
        r = st
        if miss >= TRK_LOST:                           # lost: the track is free again
            st = S_SEARCH
            r = S_LOST
    sc_set(t, b + SC_STATE, st)
    sc_set(t, b + SC_MISS, miss)
    sc_set(t, b + SC_CX, cx)
    sc_set(t, b + SC_CY, cy)
    sc_set(t, b + SC_VX, vx + V_BIAS)
    sc_set(t, b + SC_VY, vy + V_BIAS)
    return r


def nearest_blob(c, t, b, used):
    """The unused blob of class c nearest the predicted centre of the track at word b, within its
    gate; -1 when none."""
    pcx = sc_get(t, b + SC_CX) + sc_get(t, b + SC_VX) - V_BIAS
    pcy = sc_get(t, b + SC_CY) + sc_get(t, b + SC_VY) - V_BIAS
    best = -1
    bd = sc_get(t, b + SC_W) + sc_get(t, b + SC_H) + TRK_GATE + 1
    i = 0
    while i < NBLOB:
        if not used & (1 << i):
            if blob_ok(c, t, i):
                x = mem32[t + TRK_BLOB_X + (i << 2)]
                y = mem32[t + TRK_BLOB_Y + (i << 2)]
                d = absv((x & 0xFFFF) + (x >> 16) - pcx) + absv((y & 0xFFFF) + (y >> 16) - pcy)
                if d < bd:
                    bd = d
                    best = i
        i += 1
    return best


def pred_lo(c, v, size):
    """Low edge of the predicted box: centre c (x 2) moved by v, half of size below it."""
    return (c + v - size) >> 1


def pred_hi(c, v, size):
    return (c + v + size) >> 1
