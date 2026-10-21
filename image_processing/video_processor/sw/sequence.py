"""video_processor firmware: frame counters and the image sequence (section 7).

Once the pipeline is idle every frame count is cleared and the event log started on all channels,
so the camera's image sequence (GPIO0[29] = 1) is counted from 0 and every frame is followed
through the pipeline in the transcript: first stage (interrupt 13), into and out of
vision_system, measured by object_tracker, last stage (interrupt 14).
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *
from events import *

# CPU clock cycles (CYCLES register; 200 MHz in the testbench)
SEQ_WAIT = 16000000                # 80 ms: wait for the camera's image sequence
QUIET = 100000                     # 0.5 ms without an event: the pipeline is empty
fc_first = 0                       # frame_counter COUNT0, read at its last end-of-frame interrupt
fc_last = 0                        # frame_counter COUNT1, read at its last end-of-frame interrupt
seq_seen = 0                       # GPIO0[29] rising edge seen: the camera started a sequence


def wait_idle():
    """Wait until no frame has ended at either stage for QUIET cycles."""
    c0 = mem32[FC + FC_COUNT0]
    c1 = mem32[FC + FC_COUNT1]
    t = deadline(QUIET)
    irq_disable()
    while not passed(t):                               # woken by the frame interrupts (13 / 14) or the
        sleep_until(t)                                 # timer at the end of the quiet time
        n0 = mem32[FC + FC_COUNT0]
        n1 = mem32[FC + FC_COUNT1]
        if n0 != c0 or n1 != c1:
            c0 = n0
            c1 = n1
            t = deadline(QUIET)
    irq_enable()


def wait_sequence():
    """Wait for the camera's sequence to start (GPIO0[29] rising edge, latched by the interrupt
    handler); True when it did within SEQ_WAIT."""
    t = deadline(SEQ_WAIT)
    irq_disable()
    while not seq_seen and not passed(t):              # the GPIO0 interrupt sets it
        sleep_until(t)
    irq_enable()
    return seq_seen


def frame_sequence():
    global stage, fc_first, fc_last, seq_seen
    stage = 160
    heading("7. Frame counters and image sequence (events in the order they happened)")
    say("  frame_counter @ 0x18400 logs every frame marker with its time (us), in order:")
    say("    IRQ 13  COUNT0: end of frame out of csi2_raw_unpack (first stage)")
    say("    vision_system takes / outputs frame n: into and out of lens correction")
    say("    tracker frame n: object_tracker measured it (after blur_sharpen)")
    say("    IRQ 14  COUNT1: end of frame into axis_to_video (last stage)")
    puts("  Live camera frames so far: first stage ")
    dec(fc_first)
    puts(", last stage ")
    dec(fc_last)
    nl()
    wait_idle()                                        # then count the sequence from 0
    irq_disable()
    events_start(EV_ALL)
    fc_first = 0
    fc_last = 0
    seq_seen = 0
    irq_enable()
    result(mem32[FC + FC_COUNT0] == 0 and mem32[FC + FC_COUNT1] == 0,
           "FRAME_CNT: pipeline idle, counters and event log cleared before the image sequence")
    stage = 161                                        # listening for the image sequence
    if not wait_sequence():
        say("  No image sequence (GPIO0[29] stayed low)")
        return
    say("  Image sequence started (GPIO0[29] rose):")
    events_run(0, QUIET)
    events_stop()
    puts("  Sequence: ")
    dec(fc_first)
    puts(" frames at the first stage, ")
    dec(fc_last)
    puts(" at the last stage, ")
    dec(ev_count)
    say(" events reported")
    result(fc_first > 0 and fc_last == fc_first and not ev_lost,
           "FRAME_CNT: every frame counted at both stages and reported in order")
