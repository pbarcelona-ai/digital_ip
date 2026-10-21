"""video_processor firmware: object detection and tracking (section 8).

The camera may send several tracking sequences one after the other (camera register 0x56, the
count; 0x57 the number of the sequence whose settings are loaded): for each, the sequence's frame
size comes from the camera (registers 0x30-0x33) and is set in every block; so are the object
classes to detect, their symbol styles and the most targets tracked at a time (registers 0x50-0x55
and 0x58, camera_detect) and the image name (0x40-0x4F). Each selected class's detector searches the whole
frame and symbol_overlay waits for a target. The transcript logs the first stage, the tracker and
the last stage of every frame (only the tracker with the direct-transcript strap); on each tracker
event (track_event) the firmware reads every selected detector's blobs, checks their shapes
(class_ok), matches them to the class's tracks (tracker.py), moves each target's box (overlay.py) to
its predicted position for the next frame, and completes the event's line with the results: per
target its class letter, its label (P<n> person, G<n> ground transport, A<n> aircraft: drawn below
its symbol; - a face of a labelled pedestrian), state, measured box and pixels, and the box the
overlay draws on the next frame.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *
from camera import *
from search import *
from overlay import *
from tracker import *
from bytetrack import *
from events import *

# per-frame words, packed 4 characters a word (putw: no flash read)
W_TRACK = 0x41525420               # " TRA" "CK x" " "
W_TRACK1 = 0x78204B43
W_COAST = 0x414F4320               # " COA" "ST x" " "
W_COAST1 = 0x78205453
W_SP = 0x20                        # " "
W_Y = 0x207920                     # " y "
W_PX = 0x787020                    # " px"
W_BOX = 0x6F62202C                 # ", bo" "x x "
W_BOX1 = 0x20782078
W_LOST = 0x534F4C20                # " LOS" "T"
W_LOST1 = 0x54
W_BAR = 0x7C20                     # " |"
W_COMMA = 0x202C                   # ", "
TRK_QUIET = 60000000               # 300 ms without an event after the tracking sequence: done (longer than the
                                   # NPU's run on the last frame: about 90 ms for YOLOv8s at 1920 x 1088)
LOAD_WAIT = 40000000               # 200 ms: wait for the camera to load the next sequence's settings
LOAD_STEP = 20000                  # 100 us between two reads of its "loaded" register
trk_base = 0                       # FRAMES of the first selected detector when the sequence started
first_cls = 0                      # that detector's address
seq_no = 0                         # tracking sequence being run (1, 2, ...)
step_sum = 0                       # CPU cycles of the tracking steps (track_event) of this sequence
step_max = 0                       # the longest one


def track_setup(total):
    """Sequence seq_no of total: every block for the camera's frame size; the selected detectors searching, overlay on, no
    box yet."""
    global log_wr, first_cls, trk_frames, trk_found, step_sum, step_max
    heading("8. Object detection and tracking (frame size and classes from the camera)")
    puts("  Tracking sequence ")
    dec(seq_no)
    puts(" of ")
    dec(total)
    nl()
    say("  Every register write of the tracking set-up: <module> <register>, old value, new value, what it does")
    ok = camera_frame_size()
    ok = camera_detect() and ok
    log_wr = 1
    wreg(VP + VP_CTRL, 0, strings(                     # display stopped while the frame size changes
        "video_pipeline CTRL",
        "0 = pipeline and display stopped while the frame size changes",
        "(no frame is cut between two sizes)"))
    fs = frame_size(cam_w, cam_h)
    wreg(VP + VP_CTRL, CTRL_ENABLE | CTRL_HDMI | CTRL_LOCK | CTRL_INSERT, strings(
        "video_pipeline CTRL",
        "[0] pipeline on, [1] HDMI output, [3] genlock, [7] insert",
        "point on: video restarts at the camera's tracking frame size"))
    result(ok and fs, "frame size and detection options read over I2C 0, size set in every block")
    ids = mem32[OVL] == SOVL
    c = 0
    while c < NDET:
        if mem32[det_base(c)] != OTRK:
            ids = 0
        c += 1
    if mem32[FEAT] != FEAT_ID:
        ids = 0
    result(ids, "object_tracker: 5 detectors with ID \"OTRK\", feature_detect \"FEAT\", symbol_overlay \"SOVL\"")
    tracker_setup()
    feature_setup()
    c = 0
    while not det_mask & (1 << c):
        c += 1
    first_cls = det_base(c)
    detector_select()
    n = camera_name(T_NAME)
    overlay_setup(n)
    log_wr = 0
    trk_frames = 0
    trk_found = 0
    step_sum = 0
    step_max = 0
    say("  SEARCH: each selected detector looks at the whole frame; each object it finds (a blob of")
    say("    the class's shape) is matched to the nearest predicted target of its class, or starts")
    say("    a new one while fewer than the most targets are tracked")
    say("  symbol_overlay: object 3c + k = target k of class c, its label below it; text: image name")
    say("    (camera registers 0x40-0x4F) upper left, clock upper right, frame number lower left")
    say("  Line per frame: <class letter> <label> <state> x <measured columns> y <lines>, <pixels>,")
    say("    box x .. y ..: the box the overlay draws on the next frame (the predicted position);")
    say("    class letters P pedestrian, F face, A automobile, V vehicle, J aircraft")


def detector_select():
    """The NPU detector and ByteTrack when the NPU and its program are there (the feature detectors then
    stay off), else the feature detectors and their tracker (npu_mode 0)."""
    global npu_mode
    npu_mode = 0
    if npu_present():
        npu_mode = 1
        c = 0
        while c < NDET:
            mem32[det_base(c) + TRK_CTRL] = 0
            c += 1
        npu_setup()
        say("  NPU detector (ID \"NPU8\", program in DDR) and ByteTrack-type tracking: on")
    else:
        say("  No NPU program in DDR: the feature detectors and their tracker")


def feature_setup():
    """feature_detect for the sequence: the frame size, edges (Sobel above 128, filled over 8 pixels),
    motion (20 beyond the background cell's range, filled over 2, background rate 1/4), the camera shift
    found automatically; restarted, so its first frame fills the background."""
    wreg(FEAT + F_SIZE, (cam_h << 16) | cam_w, strings(
        "feature_detect FRAME_SIZE",
        "[15:0] width, [31:16] height of the sequence's frames", ""))
    wreg(FEAT + F_EDGE, (8 << 16) | 128, strings(
        "feature_detect EDGE",
        "[10:0] 128: Sobel |Gx| + |Gy| above 128 is an edge, [19:16] 8:",
        "an edge in the last 8 pixels marks the pixel (solid runs)"))
    wreg(FEAT + F_MOTION, (2 << 12) | (2 << 8) | 20, strings(
        "feature_detect MOTION",
        "[7:0] 20 beyond the background cell's range: moving, [11:8]",
        "2: filled over 2 pixels, [14:12] 2: background learns 1/4"))
    wreg(FEAT + F_SKY_CFG, (SKY_Y << 8) | sky_shift(), strings(
        "feature_detect SKY_CFG",
        "[3:0] sky profile column groups of 2 ** SHIFT pixels (at most",
        "32), [15:8] 100: sky pixels smooth and luma 100 or more"))
    wreg(FEAT + F_CTRL, 0x1F, strings(
        "feature_detect CTRL",
        "[0] on, [1] edges, [2] motion, [3] camera shift found by the",
        "profiles, [4] restart: the first frame fills the background"))


def class_letter(c):
    """Class tag of the transcript: P pedestrian, F face, A automobile, V vehicle, J aircraft (jet)."""
    if c == C_PED:
        putc(80)
    elif c == C_FACE:
        putc(70)
    elif c == C_CAR:
        putc(65)
    elif c == C_VEH:
        putc(86)
    else:
        putc(74)


def range_out(a, b):
    dec(a)
    putc(45)
    dec(b)


def track_report(c, t, k, r, i, first):
    """Target k of class c after its step (r: track_step's result, i: its blob or -1, first: its
    class's first target on the line): its part of the line and its box for the next frame;
    returns 1 when the target is still tracked."""
    global trk_live
    if not first:
        putc(59)
    putc(32)
    class_letter(c)
    putc(32)
    w = mem32[obj_label(c, k)]
    if w == 0:                                         # a face of a labelled pedestrian
        w = 45                                         # "-"
    putw(w)
    if r == S_LOST:
        overlay_off(c, k)
        trk_live -= 1
        putw(W_LOST)
        putw(W_LOST1)
        return 0
    b = track_word(k)
    if i < 0:                                          # coasting: the predicted box of this frame
        w = sc_get(t, b + SC_W)
        h = sc_get(t, b + SC_CX)
        putw(W_COAST)
        putw(W_COAST1)
        putw(W_SP)
        range_out(pred_lo(h, 0, w), pred_hi(h, 0, w))
        w = sc_get(t, b + SC_H)
        h = sc_get(t, b + SC_CY)
        putw(W_Y)
        range_out(pred_lo(h, 0, w), pred_hi(h, 0, w))
    else:
        w = mem32[t + TRK_BLOB_X + (i << 2)]
        h = mem32[t + TRK_BLOB_Y + (i << 2)]
        putw(W_TRACK)
        putw(W_TRACK1)
        putw(W_SP)
        range_out(w & 0xFFFF, w >> 16)
        putw(W_Y)
        range_out(h & 0xFFFF, h >> 16)
        putw(W_COMMA)
        dec(mem32[t + TRK_BLOB_N + (i << 2)])
        putw(W_PX)
    next_box(c, k, t, b)
    return 1


def next_box(c, k, t, b):
    """Target k of class c (SCRATCH word b of detector t): its box at the predicted position for the
    next frame, printed as the overlay draws it."""
    cx = sc_get(t, b + SC_CX)
    cy = sc_get(t, b + SC_CY)
    vx = sc_get(t, b + SC_VX) - V_BIAS
    vy = sc_get(t, b + SC_VY) - V_BIAS
    x0 = clip(pred_lo(cx, vx, 0) - mark_half, cam_w - 1 - (mark_half << 1))   # every symbol the same
    x1 = x0 + (mark_half << 1)                         # size on the predicted centre of the target,
    y0 = clip(pred_lo(cy, vy, 0) - mark_half, cam_h - 1 - (mark_half << 1))   # moved inside the frame
    y1 = y0 + (mark_half << 1)
    n = sc_get(t, b + SC_FOUND)
    if n >= CONFIRM and mem32[obj_label(c, k)] == 0:   # confirmed: labelled once (it keeps the label
        label_new(c, k, (cx + vx) >> 1, (cy + vy) >> 1)   # while tracked, coasting too)
    if n < CONFIRM or (c == C_PED and face_of(t, b) >= 0):   # tentative, or a person whose face is
        overlay_off(c, k)                              # tracked: the face carries the symbol and label
    else:
        overlay_box(c, k, x0, y0, x1, y1)
    putw(W_BOX)
    putw(W_BOX1)
    range_out(x0, x1)
    putw(W_Y)
    range_out(y0, y1)


def new_blob(c, t, i):
    """Blob i of detector t can start a target of class c: its shape, and not the same object as a
    target of the class already (another term's blob of it)."""
    if not blob_ok(c, t, i):
        return 0
    x = mem32[t + TRK_BLOB_X + (i << 2)]
    y = mem32[t + TRK_BLOB_Y + (i << 2)]
    return not in_target(c, ((x & 0xFFFF) + (x >> 16)) >> 1, ((y & 0xFFFF) + (y >> 16)) >> 1)


def biggest_blob(c, t, used):
    """The unused blob of detector t with the most pixels that can start a target of class c, or -1."""
    best = -1
    bn = 0
    i = 0
    while i < NBLOB:
        if not used & (1 << i):
            n = mem32[t + TRK_BLOB_N + (i << 2)]
            if n > bn and new_blob(c, t, i):
                bn = n
                best = i
        i += 1
    return best


def face_of(t, b):
    """A confirmed face target inside the box of the pedestrian at SCRATCH word b of detector t (or
    just above it: the head over a dark body): its number, or -1."""
    f = det_base(C_FACE)
    x = sc_get(t, b + SC_CX)
    w = sc_get(t, b + SC_W)
    y = sc_get(t, b + SC_CY)
    h = sc_get(t, b + SC_H)
    k = 0
    while k < NTR:
        q = track_word(k)
        if sc_get(f, q + SC_STATE) != S_SEARCH and sc_get(f, q + SC_FOUND) >= CONFIRM:
            cx = sc_get(f, q + SC_CX)
            cy = sc_get(f, q + SC_CY)
            if cx >= x - w and cx <= x + w and cy >= y - h - (h >> 1) and cy <= y + h:
                return k
        k += 1
    return -1


def free_track(t):
    """A free track of detector t's class, or -1."""
    k = 0
    while k < NTR:
        if sc_get(t, track_word(k) + SC_STATE) == S_SEARCH:
            return k
        k += 1
    return -1


def track_class(c, part):
    """Class c's step on this frame's blobs: every live target takes its nearest blob (or coasts),
    blobs left over start new targets; prints the class's part of the transcript line (part: not
    the first class on it). Returns 1 when the class has a target tracked."""
    global trk_live
    t = det_base(c)
    if part:
        putw(W_BAR)
    first = 1
    live = 0
    used = 0
    found = 0
    k = 0
    while k < NTR:                                     # live targets: nearest blob of the class
        b = track_word(k)
        if sc_get(t, b + SC_STATE) != S_SEARCH:
            i = -1
            if c == C_AIR or not in_target(C_AIR, sc_get(t, b + SC_CX) >> 1, sc_get(t, b + SC_CY) >> 1):
                i = nearest_blob(c, t, b, used)
            else:                                      # an engine, window or the nose of a tracked
                sc_set(t, b + SC_MISS, TRK_LOST)       # aircraft: given up at once
            if i >= 0:
                used = used | (1 << i)
                found = 1
            r = track_step(t, b, i)                    # (one call at a time: the operand stack is shared)
            if track_report(c, t, k, r, i, first):
                live = 1
            first = 0
        k += 1
    k = free_track(t)
    while k >= 0 and trk_live < max_targets:           # the other blobs: new targets, largest first
        i = biggest_blob(c, t, used)                   # (the foreground has the priority)
        if i < 0:
            break
        used = used | (1 << i)
        trk_live += 1
        found = 1
        live = 1
        mem32[obj_label(c, k)] = 0                     # labelled once confirmed (next_box)
        r = track_step(t, track_word(k), i)
        track_report(c, t, k, r, i, first)
        first = 0
        k = free_track(t)
    if found:
        sc_set(t, SC_CLASS_FOUND, sc_get(t, SC_CLASS_FOUND) + 1)
    if first:
        putc(32)
        class_letter(c)
        puts(" SEARCH, nothing found")
    return live


def track_event(n):
    """Tracker event of frame n (events.py): every selected class measured, stepped, its boxes
    moved; completes the transcript line ("tracker frame n:" then, per class, its targets). trk_frames
    counts the event once the boxes are committed (the testbench sends the next GIF frame after
    that)."""
    global trk_frames, trk_found, step_sum, step_max
    t0 = now()
    if npu_mode:
        if mem32[NPU + N_RUNS] - trk_base != n:        # the report fell behind: a later frame's results
            puts(" (late)")
    elif mem32[first_cls + TRK_FRAMES] - trk_base != n:
        puts(" (late)")
    putc(58)
    text_clock(mem32[FC + FC_TIME])                    # the clock of the next frame
    any = 0
    if npu_mode:                                       # the NPU's detections, ByteTrack
        bt_event(n)
        any = confirmed()
    else:
        part = 0
        c = C_AIR                                      # aircraft first: a plane's engines, windows and
        while c >= 0:                                  # nose are then not taken for people or vehicles
            if det_mask & (1 << c):
                if track_class(c, part):
                    any = 1
                part = 1
            if c == C_AIR:
                c = 0
            else:
                c += 1
            if c == C_AIR:
                c = -1
    nl()
    if any:
        trk_found += 1
    overlay_commit()
    trk_frames += 1
    t0 = now() - t0
    step_sum += t0
    if t0 > step_max:
        step_max = t0


def track_sequence(total):
    """One tracking sequence: set up, then the transcript with one tracking step per tracker event
    until the camera's sequence (GPIO0[29] = 1) has ended and the pipeline is empty."""
    global stage, seq_seen, trk_base, fc_first, fc_last
    track_setup(total)
    irq_disable()
    if direct():
        events_start(1 << EV_TRACK)                    # direct transcript: the tracker lines only
    else:
        events_start((1 << EV_FIRST) | (1 << EV_TRACK) | (1 << EV_LAST))
    fc_first = 0
    fc_last = 0
    seq_seen = 0
    irq_enable()
    trk_base = mem32[first_cls + TRK_FRAMES]
    if npu_mode:
        trk_base = mem32[NPU + N_RUNS]
    stage = 170                                        # set up: the camera may send the sequence
    result(wait_sequence(), "camera: tracking sequence started (GPIO0[29] rose)")
    if seq_seen:
        events_run(1, TRK_QUIET)
    events_stop()
    stage = 180
    puts("  Sequence: ")
    dec(trk_frames)
    puts(" frames, a target found in ")
    dec(trk_found)
    nl()
    if trk_frames:                                     # CPU time per frame (200 MHz: cycles / 200 = us)
        puts("  Tracking step (CPU, per frame): average ")
        dec(div(div(step_sum, trk_frames), 200))
        puts(" us, longest ")
        dec(div(step_max, 200))
        say(" us")
    if npu_mode:
        puts("  NPU: ")
        dec(mem32[NPU + N_RUNS])
        puts(" runs, ")
        dec(mem32[NPU + N_CYC])
        puts(" clocks the last; ")
        dec(bt_tracks)
        say(" tracks confirmed (ByteTrack)")
    else:
        c = 0
        while c < NDET:
            if det_mask & (1 << c):
                puts("    ")
                class_name(c)
                puts(": found in ")
                dec(sc_get(det_base(c), SC_CLASS_FOUND))
                puts(" of ")
                dec(trk_frames)
                say(" frames")
            c += 1
    result(trk_frames > 0 and not ev_lost, "tracking: every frame measured, each box follows its target")


def track():
    """Section 8: every tracking sequence the camera sends (register 0x56), each once the camera has
    loaded its settings (register 0x57 = its number)."""
    global con, seq_no, stage
    if direct():                                         # direct transcript: the tracking is written
        mem32[GPIO1 + G_DIR] = 0xFFFFFFFF
        con = 2
    total = camera_byte(SENSOR_SEQS)
    if total == 0:
        total = 1
    seq_no = 1
    while seq_no <= total:
        stage = 169                                    # waiting for the sequence's settings
        t = deadline(LOAD_WAIT)
        while camera_byte(SENSOR_LOADED) < seq_no and not passed(t):
            pause(LOAD_STEP)                           # the camera has no interrupt line: asked again
                                                       # after a sleep
        track_sequence(total)
        seq_no += 1
