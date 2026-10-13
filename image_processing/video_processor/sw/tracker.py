"""video_processor firmware: object_tracker set-up and the tracking state machine.

States: SEARCH (whole frame), TRACK (target found: window around the prediction), COAST (target
missed: the box keeps moving with the velocity), back to SEARCH after TRK_LOST misses in a row.
Centres and velocities are kept x 2 (x0 + x1) and the box size grows at once but shrinks by a
quarter of the difference per frame, so everything is adds and shifts (py_core has no multiply or
divide). pred_lo / pred_hi give the predicted box for the next frame.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

TRK_LEVEL = 80                     # luma below this is the target (dark pedestrian, light scene)
TRK_MIN_RUN = 2                    # horizontal runs of at least 2 target pixels (single-pixel noise ignored)
TRK_MIN_PIX = 40                   # target pixels for a detection
TRK_LOST = 4                       # frames missed before searching the whole frame again
S_SEARCH = 0
S_TRACK = 1
S_COAST = 2
S_LOST = 3                         # returned once by tracker_step: the target was just given up
trk_state = 0                      # S_SEARCH, S_TRACK or S_COAST
trk_miss = 0                       # frames missed in a row
trk_cx = 0                         # box centre x 2 (x0 + x1), y 2
trk_cy = 0
trk_vx = 0                         # centre velocity, x 2 pixels per frame (smoothed)
trk_vy = 0
trk_w = 0                          # box width, height (x1 - x0, y1 - y0)
trk_h = 0
trk_frames = 0                     # tracker frames processed
trk_found = 0                      # frames with the target found


def tracker_setup():
    """Dark target below TRK_LEVEL in runs of TRK_MIN_RUN+, searching the whole frame."""
    global trk_state, trk_miss
    wreg(TRK + TRK_THRESH, TRK_LEVEL, strings(
        "object_tracker THRESH",
        "[7:0] luma threshold 80: pixels with luma (R + 2G + B) / 4",
        "below 80 are target pixels (dark pedestrian on a light scene)"))
    wreg(TRK + TRK_CTRL, 3 | (TRK_MIN_RUN << 8), strings(       # enabled, dark target
        "object_tracker CTRL",
        "[0] measuring on, [1] dark target (below THRESH), [11:8] 2 =",
        "horizontal runs of 2+ target pixels count (noise ignored)"))
    search_whole_frame()
    trk_state = S_SEARCH
    trk_miss = 0


def smooth_size(size, measured):
    """Grow to the measured size at once, shrink by a quarter of the difference."""
    if trk_state == S_SEARCH or measured > size:
        return measured
    return size - ((size - measured) >> 2)


def tracker_step(n, x0, y0, x1, y1):
    """One frame's measurement (n target pixels, box x0..x1, y0..y1): the new state."""
    global trk_state, trk_miss, trk_cx, trk_cy, trk_vx, trk_vy, trk_w, trk_h, trk_found
    if n >= TRK_MIN_PIX:                               # found: velocity from the centre's move
        trk_found += 1
        if trk_state == S_SEARCH:
            trk_vx = 0
            trk_vy = 0
        else:
            trk_vx = (trk_vx + x0 + x1 - trk_cx) >> 1
            trk_vy = (trk_vy + y0 + y1 - trk_cy) >> 1
        trk_w = smooth_size(trk_w, x1 - x0)
        trk_h = smooth_size(trk_h, y1 - y0)
        trk_cx = x0 + x1
        trk_cy = y0 + y1
        trk_state = S_TRACK
        trk_miss = 0
    elif trk_state != S_SEARCH:                        # missed: coast with the velocity
        trk_miss += 1
        trk_cx = trk_cx + trk_vx
        trk_cy = trk_cy + trk_vy
        trk_state = S_COAST
        if trk_miss >= TRK_LOST:                       # lost: search the whole frame again
            trk_state = S_SEARCH
            return S_LOST
    return trk_state


def pred_lo(c, v, size):
    """Low edge of the predicted box: centre c (x 2) moved by v, half of size below it."""
    return (c + v - size) >> 1


def pred_hi(c, v, size):
    return (c + v + size) >> 1
