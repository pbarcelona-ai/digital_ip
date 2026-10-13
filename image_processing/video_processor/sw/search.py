"""video_processor firmware: object_tracker search windows.

The tracker looks for the target only inside its search window (inclusive, taken at each frame
start): the whole frame while searching, else the predicted box plus TRK_MARGIN pixels.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

TRK_MARGIN = 12                    # search window: predicted box + 12 pixels each side


def clip(v, hi):
    """v limited to 0 .. hi."""
    if v < 0:
        return 0
    if v > hi:
        return hi
    return v


def search_window(x0, y0, x1, y1):
    """object_tracker search window (inclusive), used from its next frame start."""
    wreg(TRK + TRK_WIN_X, (x1 << 16) | x0, strings(
        "object_tracker WIN_X",
        "search window columns [15:0] first, [31:16] last: only pixels",
        "inside are measured, from the tracker's next frame start"))
    wreg(TRK + TRK_WIN_Y, (y1 << 16) | y0, strings(
        "object_tracker WIN_Y",
        "search window lines [15:0] first, [31:16] last (with WIN_X the",
        "whole frame while searching, else around the prediction)"))


def search_whole_frame():
    search_window(0, 0, cam_w - 1, cam_h - 1)


def search_around(x0, y0, x1, y1):
    """The box x0..x1, y0..y1 widened by TRK_MARGIN on every side, inside the frame."""
    search_window(clip(x0 - TRK_MARGIN, cam_w - 1), clip(y0 - TRK_MARGIN, cam_h - 1),
                  clip(x1 + TRK_MARGIN, cam_w - 1), clip(y1 + TRK_MARGIN, cam_h - 1))
