"""video_processor firmware: pedestrian tracking (section 8).

The tracking sequence's frame size comes from the camera (registers 0x30-0x33) and is set in
every block; the tracker searches the whole frame and symbol_overlay waits for a target. The
transcript logs the first stage, the tracker and the last stage of every frame; on each tracker
event (track_event) the firmware reads the measurement, runs the state machine (tracker.py), moves
the dashed box (overlay.py) and the search window (search.py) to the predicted position for the
next frame, and completes the event's line with the result.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *
from camera import *
from search import *
from overlay import *
from tracker import *
from events import *

TRK_QUIET = 400000                 # 2 ms without an event after the tracking sequence: done
trk_base = 0                       # tracker FRAMES when the sequence started


def track_setup():
    """Every block for the camera's frame size; tracker searching, overlay on, no box yet."""
    global log_wr
    heading("8. Pedestrian tracking (frame size from the camera)")
    say("  Every register write of the tracking set-up: <module> <register>, old value, new value, what it does")
    ok = camera_frame_size()
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
    result(ok and fs, "frame size read over I2C 0, set in camera input, vision_system, filter, tracker, display")
    result(mem32[TRK] == OTRK and mem32[OVL] == SOVL,
           "object_tracker: ID \"OTRK\", symbol_overlay: ID \"SOVL\"")
    tracker_setup()
    n = camera_name(T_NAME)
    overlay_setup(n)
    log_wr = 0
    say("  object_tracker: target = luma below 80 in runs of 2+ pixels; SEARCH: whole frame")
    say("  symbol_overlay: object 0 = dashed green box around the pedestrian; text: image name")
    say("    (camera registers 0x40-0x4F) upper left, clock upper right, frame number lower left")


def track_event(n):
    """Tracker event of frame n (events.py): measure, step, move the box and the window; completes
    the transcript line."""
    global trk_frames
    trk_frames += 1
    if mem32[TRK + TRK_FRAMES] - trk_base != n:       # the report fell behind: a later frame's results
        puts(" (late)")
    cnt = mem32[TRK + TRK_COUNT]
    bx = mem32[TRK + TRK_BOX_X]
    by = mem32[TRK + TRK_BOX_Y]
    x0 = bx & 0xFFFF
    x1 = bx >> 16
    y0 = by & 0xFFFF
    y1 = by >> 16
    st = tracker_step(cnt, x0, y0, x1, y1)
    text_clock(mem32[FC + FC_TIME])                    # the clock of the next frame
    if st == S_SEARCH or st == S_LOST:
        overlay_off()
        overlay_commit()
        search_whole_frame()
        if st == S_LOST:
            say(": LOST, searching the whole frame again")
        else:
            say(": SEARCH, nothing found")
        return
    if st == S_COAST:                                  # the predicted box of this frame
        x0 = pred_lo(trk_cx, 0, trk_w)
        x1 = pred_hi(trk_cx, 0, trk_w)
        y0 = pred_lo(trk_cy, 0, trk_h)
        y1 = pred_hi(trk_cy, 0, trk_h)
        puts(": COAST x ")
    else:
        puts(": TRACK x ")
    dec(x0)
    putc(45)
    dec(x1)
    puts(" y ")
    dec(y0)
    putc(45)
    dec(y1)
    puts(", ")
    dec(cnt)
    say(" px")
    # next frame: dashed box and search window at the predicted position
    x0 = pred_lo(trk_cx, trk_vx, trk_w)
    x1 = pred_hi(trk_cx, trk_vx, trk_w)
    y0 = pred_lo(trk_cy, trk_vy, trk_h)
    y1 = pred_hi(trk_cy, trk_vy, trk_h)
    overlay_box(x0, y0, x1, y1)
    overlay_commit()
    search_around(x0, y0, x1, y1)


def track():
    """Section 8: set up, then the transcript with one tracking step per tracker event until the
    camera's tracking sequence (GPIO0[29] = 1) has ended and the pipeline is empty."""
    global stage, seq_seen, trk_base, fc_first, fc_last
    track_setup()
    irq_disable()
    events_start((1 << EV_FIRST) | (1 << EV_TRACK) | (1 << EV_LAST))
    fc_first = 0
    fc_last = 0
    seq_seen = 0
    irq_enable()
    trk_base = mem32[TRK + TRK_FRAMES]
    stage = 170                                        # set up: the camera may send the sequence
    result(wait_sequence(), "camera: tracking sequence started (GPIO0[29] rose)")
    if seq_seen:
        events_run(1, TRK_QUIET)
    events_stop()
    stage = 180
    puts("  Sequence: ")
    dec(trk_frames)
    puts(" frames, pedestrian found in ")
    dec(trk_found)
    nl()
    result(trk_frames > 0 and trk_found == trk_frames and not ev_lost,
           "tracking: pedestrian found in every frame, dashed box follows it")
