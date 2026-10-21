"""video_processor firmware: the program (interrupt handler and main).

Compiled with ip/cpu/py_core/tools/pyc.py into one flash image (scripts/run_sim.sh does it; pyc.py
inlines every module imported below, each once, into one global namespace); the py_soc boot loader
copies it from SPI flash at reset. Modules (sw/):
  video_init.py   CPU initialisation, peripheral self-test, text output on UART 0 (sections 1-3)
  video_regs.py   addresses, register offsets and bit values of the video blocks
  camera.py       camera control over I2C 0 (frame gap, frame size, image name, detection options,
                  stream on), image format pin
  video_setup.py  frame_size(), video set-up (section 4), video start (section 6)
  video_dump.py   video register dump (section 5)
  events.py       the frame event transcript from frame_counter's event log (true order, times)
  sequence.py     frame counters and image sequence (section 7)
  search.py       detector search windows
  tracker.py      the detectors (one object_tracker per class: pedestrian, face, automobile,
                  vehicle), the shape check and the SEARCH / TRACK / COAST state machine
  overlay.py      symbol_overlay: a box per class (colour, style) and the texts
  tracking.py     object detection and tracking (section 8)
Every step is reported on UART 0 as readable text (the testbench writes it, line by line, to
sim_transcript_<GIF name>.txt):

  1.-3. CPU initialisation (video_init.py): boot-up sequence, CPU
     peripheral self-test, CPU register dump. The external reset holds the
     whole system; its release starts the CPU boot, while the core logic
     (video datapath) stays in reset until the CPU, having booted and passed
     its self-test, releases it (SYSCTL CORE_RESET). Without that release
     (a self-test failed) the video sections are skipped.
  4. Video set-up, every video register programmed with the camera still
     stopped: display serial clocks on (SYSCTL CLK_EN), camera out of
     reset (GPIO0[0]), camera frame gap (end of one frame to the start of
     the next, FRAME_GAP_NS = 1280 ns, CCI registers
     0x20-0x21 over I2C 0), vision_system identity correction, blur_sharpen
     MODE 3, video_pipeline with the insert point, image format, frame
     counter and statistics interrupts. Every register write is reported
     (wreg in video_init.py) as
         <module> <register>
           old value 0x........
           new value 0x........   (read back after the write)
           <what the change does, one or two lines>
     The tracking set-up of section 8 reports its writes the same way; the
     per-frame updates during tracking (box, search window, clock text,
     commit), the I2C data bytes and the interrupt handler's acknowledges
     are not reported (they would delay the real-time transcript).
     The camera image format comes from the GPIO0[30] input (1 = monochrome:
     every ISP stage bypassed, the raw value on R, G and B; 0 = colour: RGGB
     demosaic on). An interrupt on either edge reprograms the ISP BYPASS
     register (set_format, applied by the ISP at the next frame start) and
     GPIO0[2] shows the format programmed.
  5. End of the video set-up: every video_processor register, the CPU
     peripherals (py_soc: SYSCTL, INTC, WDT, GPIO0-2, UART0-1, I2C0-1, SPI0-1,
     flash) and the video blocks (video_pipeline, its scaler, vision_system,
     blur_sharpen, frame_counter, object_tracker, symbol_overlay), address,
     name, short description and value (skipped when the GPIO0[31] strap
     is high: quick simulation; the set-up write reports of section 4 still
     run).
  6. Video start: camera "stream on" over I2C 0, frames, checks.
  7. Frame counters and image sequence: frame_counter counts the ends of
     frame of the first pipeline stage (csi2_raw_unpack, interrupt 13,
     COUNT0) and of the last one (into axis_to_video, interrupt 14, COUNT1);
     the interrupt handler reads the respective counter at each one. Once
     the pipeline is idle every count and the event log are cleared, so the
     image sequence (GPIO0[29] = 1) is counted from 0, and every frame is
     followed through the pipeline in the transcript, one line per event in
     the order the events happened, with its time (frame_counter's event
     log, events.py): first stage (IRQ 13, COUNT0), into and out of
     vision_system, measured by object_tracker, last stage (IRQ 14, COUNT1).
  8. Object detection and tracking: the camera's frame size for the
     tracking sequence is read from its control registers 0x30-0x33 (width,
     height, high byte first, over I2C 0) and every block is reprogrammed
     for it (frame_size); the classes to detect and their box styles come
     from registers 0x50-0x54. Each selected class's detector searches the
     whole frame for its class (pedestrian: dark; face: skin tone;
     automobile / vehicle: saturated paint in car- or bus-length runs) and
     symbol_overlay draws the class's box (its colour, the chosen dashed or
     solid rectangle or circle) around what it finds. For every
     frame of the camera's tracking sequence (GPIO0[29] = 1 again) the
     transcript shows the first stage, the tracker and the last stage; at
     the tracker event the firmware reads each selected detector's box,
     checks its shape, predicts where the target will be in the next frame
     (centre velocity, shifts only: no multiply or divide in py_core), moves
     the class's box and search window there and completes the line with
     the results. States: SEARCH (whole frame),
     TRACK (window around the prediction), COAST (target missed, box
     keeps moving with the velocity), back to SEARCH after TRK_LOST misses.
  9. Summary and "END OF REPORT".

Text lives in a string table in flash (pyc.py: a string literal is a handle);
puts() reads it through the flash controller. The testbench watches the
`stage`, `errors` and `frames` globals: stage 3 = CPU initialised, 100 = video
running, 160 = frame-count report, 161 = waiting for the image sequence, 170 = tracking
set up (waiting for the tracking sequence), 180 = tracking report, 200 = done.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_init import *           # CPU initialisation, UART text output
from video_regs import *
from camera import *
from video_setup import *
from video_dump import *
from events import *
from sequence import *
from tracking import *


# ======================================================================= interrupts

def isr():
    global frames, fc_first, fc_last, seq_seen, log_wr
    lw = log_wr                                         # no write reports from the handler (it would
    log_wr = 0                                          # print in the middle of the set-up's lines)
    pending = mem32[INTC + INTC_MASKED]
    if pending & IRQ_GPIO0:                             # first: the next frame follows within the frame gap
        s = mem32[GPIO0 + G_INT_STATUS]
        mem32[GPIO0 + G_INT_STATUS] = s                 # write 1 to clear
        if s & MONO_SEL:
            set_format()                                # image format pin changed
        if s & SEQ_ACTIVE and mem32[GPIO0 + G_IN] & SEQ_ACTIVE:   # the camera starts a sequence (its
            seq_seen = 1                                # end, the falling edge, only wakes the report)
    if pending & IRQ_FC_FIRST:                          # end of frame, first stage: read its counter
        fc_first = mem32[FC + FC_COUNT0]
        mem32[FC + FC_STATUS] = 1                       # write 1 to clear (level source)
    if pending & IRQ_FC_LAST:                           # end of frame, last stage: read its counter
        fc_last = mem32[FC + FC_COUNT1]
        mem32[FC + FC_STATUS] = 2
    if pending & IRQ_FC_EV:                             # a logged event of channels 2-4: it wakes the
        mem32[FC + FC_STATUS] = 0x1C                    # report (events.py), the log holds it
    if pending & (IRQ_FC_FIRST | IRQ_FC_LAST | IRQ_FC_EV):   # read back: the cleared level reaches the intc
        fc_status = mem32[FC + FC_STATUS]               # ~2 cpu_clk after the write (bit_sync)
    if pending & IRQ_STATS:
        frames += 1
        mem32[INTC + INTC_PENDING] = IRQ_STATS          # edge source: write 1 to clear
    cpu_isr(pending)                                    # software, GPIO2, watchdog (video_init.py)
    log_wr = lw


# ======================================================================= main

def main():
    global stage
    start = mem32[SYSCTL + CYCLES]
    irq_handler(isr)
    if cpu_init(start):                                # sections 1-3 (video_init.py); core logic released
        video_setup()                                  # section 4
        stage = 5
        heading("5. Video set-up complete: every video_processor register (address  name  description  value)")
        if mem32[GPIO0 + G_IN] & QUICK_STRAP or direct():
            say(" (skipped: GPIO0[31] quick-simulation strap)")
        else:
            say(" CPU domain (py_soc peripherals)")
            dump_cpu()
            say(" Video domain")
            dump_video()                               # section 5
        video_start()                                  # section 6
        if errors == 0:
            mem32[GPIO0 + G_SET] = LED_RUN
        stage = 100                                    # video running: the testbench checks the outputs
        frame_sequence()                               # section 7
        track()                                        # section 8
    heading("9. Summary")
    puts("  ")
    dec(passes)
    puts(" checks passed, ")
    dec(errors)
    say(" failed")
    if errors == 0:
        say("  System ready: camera -> ISP -> vision_system -> blur_sharpen -> tracker / overlay -> HDMI / LVDS")
    else:
        say("  SYSTEM NOT READY: see the [FAIL] lines above")
    say("END OF REPORT")
    uart_drain()
    stage = 200


main()
while True:
    pass
