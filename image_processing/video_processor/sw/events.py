"""video_processor firmware: the frame event transcript.

frame_counter logs every frame marker of the enabled channels in the order the markers happened,
time-stamped in microseconds (hardware: the order and the times are exact even when the report
falls behind). The channels follow a frame through the pipeline:
  0  end of frame out of csi2_raw_unpack, the first stage (interrupt 13, COUNT0)
  2  vision_system takes the frame (vs_stream_adapter admitted it)
  3  vision_system starts sending the corrected frame
  4  object_tracker has measured the frame (after blur_sharpen)
  1  end of frame into axis_to_video, the last stage (interrupt 14, COUNT1)
event_next() reports the oldest event as one line, "  [<time> us] <what happened>", so the UART 0
transcript is the true sequence of events. Interrupts 13 / 14 are serviced as they come (isr reads
COUNT0 / COUNT1); their lines appear in the transcript at the time the frame ended.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

EV_FIRST = 0                       # event log channels (frame_counter eof_i in video_processor)
EV_LAST = 1
EV_VS_IN = 2
EV_VS_OUT = 3
EV_TRACK = 4
EV_ALL = 0x1F
SEQ_IDLE = 200000000               # 1 s: the longest sleep while the camera's sequence runs (a frame or
                                   # its end wakes the report long before)
ev_count = 0                       # events reported since events_start()
ev_lost = 0                        # 1 once the log overflowed


def events_start(mask):
    """Clear every frame count, empty the log and log the channels in mask from now on."""
    global ev_count, ev_lost
    mem32[FC + FC_EV_EN] = 0
    mem32[FC + FC_CLEAR] = EV_ALL
    while mem32[FC + FC_EVENT] & EV_VALID:
        mem32[FC + FC_EVENT_POP] = 1
    mem32[FC + FC_EVENT_POP] = 2                       # overflow flag cleared
    mem32[FC + FC_STATUS] = 0x1C
    mem32[FC + FC_IRQ_EN] = 3 | (mask & 0x1C)          # channels 2-4 logged: their markers interrupt (15)
    mem32[FC + FC_EV_EN] = mask
    ev_count = 0
    ev_lost = 0


def events_stop():
    mem32[FC + FC_EV_EN] = 0
    mem32[FC + FC_IRQ_EN] = 3


def event_next(track):
    """Report the oldest logged event as one line and remove it; returns its channel, or -1 when the
    log is empty. track = 1: a tracker event also runs the tracking step (tracking.py) on that line."""
    global ev_count, ev_lost
    e = mem32[FC + FC_EVENT]
    if not e & EV_VALID:
        return -1
    t = mem32[FC + FC_EVENT_TIME]
    mem32[FC + FC_EVENT_POP] = 1
    ch = (e >> 24) & 7
    n = e & 0xFFFFFF
    ev_count += 1
    putw(0x5B2020)                                     # "  [" (no flash read: every frame)
    dec(t)
    putw(0x5D737520)                                   # " us] "
    putc(32)
    if ch == EV_FIRST:
        puts("IRQ 13: COUNT0 = ")
        dec(n)
        say(", end of frame at the first stage")
    elif ch == EV_LAST:
        puts("IRQ 14: COUNT1 = ")
        dec(n)
        say(", end of frame at the last stage")
    elif ch == EV_VS_IN:
        puts("vision_system takes frame ")
        dec(n)
        nl()
    elif ch == EV_VS_OUT:
        puts("vision_system outputs frame ")
        dec(n)
        nl()
    else:
        putw(0x63617274)                               # "tracker frame "
        putw(0x2072656B)
        putw(0x6D617266)
        putw(0x2065)
        dec(n)
        if track:
            track_event(n)                             # completes the line
        else:
            nl()
    if e & EV_OVERFLOW and not ev_lost:
        ev_lost = 1
        say("  (event log full: later events lost)")
    return ch


def events_run(track, quiet):
    """Report every event until the camera's sequence (GPIO0[29]) has ended and no event came for
    quiet CPU cycles. With the log empty the core sleeps: a logged frame marker (interrupts 13-15),
    the sequence's end (GPIO0[29] falling, interrupt 6) or the end of the quiet time (timer) wakes it."""
    seq = 1
    t = deadline(quiet)
    while seq or not passed(t):
        if event_next(track) >= 0:
            t = deadline(quiet)
        else:
            irq_disable()
            if not mem32[FC + FC_EVENT] & EV_VALID and (not seq or mem32[GPIO0 + G_IN] & SEQ_ACTIVE):
                if seq:
                    sleep_until(deadline(SEQ_IDLE))
                else:
                    sleep_until(t)
            irq_enable()
        if seq and not mem32[GPIO0 + G_IN] & SEQ_ACTIVE:
            seq = 0
            t = deadline(quiet)


def now():
    return mem32[SYSCTL + CYCLES]
