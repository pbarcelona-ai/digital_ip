"""video_processor firmware: object_tracker search windows.

Each detector (one per object class, t = its address) looks for its targets only inside its search
window (inclusive, taken at each frame start). With several targets per class tracked, new ones
can appear anywhere, so the window is the whole frame: the detector's blobs (one per object) are
matched to the tracks by their predicted positions (tracker.py nearest_blob).
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *


def clip(v, hi):
    """v limited to 0 .. hi."""
    if v < 0:
        return 0
    if v > hi:
        return hi
    return v


def search_window(t, x0, y0, x1, y1):
    """Detector t's search window (inclusive), used from its next frame start."""
    wreg(t + TRK_WIN_X, (x1 << 16) | x0, strings(
        "object_tracker WIN_X",
        "search window columns [15:0] first, [31:16] last: only pixels",
        "inside are measured, from the tracker's next frame start"))
    wreg(t + TRK_WIN_Y, (y1 << 16) | y0, strings(
        "object_tracker WIN_Y",
        "search window lines [15:0] first, [31:16] last (with WIN_X the",
        "whole frame: targets are matched to the blobs it finds)"))


def search_whole_frame(t):
    search_window(t, 0, 0, cam_w - 1, cam_h - 1)

