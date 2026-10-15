"""video_processor firmware: video set-up (section 4) and video start (section 6).

frame_size() sets one frame size everywhere (camera input, vision_system, blur_sharpen,
object_tracker, display active area); video_setup() programs every video register with the camera
stopped, each write reported on UART 0 (wreg: module and register, old and new value, what the
change does); video_start() turns the camera on and checks that frames flow.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

FRAME_W = 32                       # live video and image sequence: 32 x 24 frames
FRAME_H = 24
FRAMES = 6                         # statistics interrupts awaited at the video start
frames = 0                         # isp_stats interrupts (counted by the interrupt handler)


def frame_size(w, h):
    """w x h frames everywhere: camera input, vision_system, blur_sharpen, object_tracker and the
    display's active area (the blanking stays). True once vision_system's reciprocals are ready."""
    s = (h << 16) | w
    wreg(VS + VS_WIDTH, w, strings(
        "vision_system IMG_WIDTH",
        "pixels per line of the corrected image; vision_system redoes",
        "its 1/width reciprocal (STATUS[2] busy until it is ready)"))
    wreg(VS + VS_HEIGHT, h, strings(
        "vision_system IMG_HEIGHT",
        "lines per frame of the corrected image; with IMG_WIDTH it sets",
        "the normalised radius used by the K1-K3 lens correction"))
    wreg(FLT + FLT_FRAME_SIZE, s, strings(
        "blur_sharpen FRAME_SIZE",
        "[15:0] width, [31:16] height: the 5 x 5 filter window's line",
        "buffers and edge replication follow this frame size"))
    wreg(TRK + TRK_SIZE, s, strings(
        "object_tracker FRAME_SIZE",
        "[15:0] width, [31:16] height: the tracker's pixel and line",
        "counters wrap at this size (box coordinates in frame pixels)"))
    wreg(VP + VP_FRAME_SIZE, s, strings(
        "video_pipeline FRAME_SIZE",
        "[15:0] width, [31:16] height of the camera frames the CSI-2",
        "receiver and the ISP expect (lines and pixels per line)"))
    wreg(VP + VP_HACT, w, strings(
        "video_pipeline H_ACTIVE",
        "display timing: visible pixels per line = the frame width;",
        "the horizontal blanking (porches, sync) is unchanged"))
    wreg(VP + VP_HACT + 16, h, strings(
        "video_pipeline V_ACTIVE",
        "display timing: visible lines per frame, the frame height; the",
        "vertical blanking is unchanged"))
    return wait_clear(VS + VS_STATUS, VS_RECIP_BUSY)


def video_setup():
    """Program every video register after the CPU initialisation; the camera is not streaming yet.
    Every write is reported (wreg: old value, new value, what it does)."""
    global stage, log_wr
    stage = 4
    heading("4. Video set-up (CPU initialisation complete, camera not streaming)")
    say("  Every register write: <module> <register>, old value, new value (read back), what it does")
    log_wr = 1
    wreg(SYSCTL + CLK_EN, CLK_VIDEO_ALL, strings(
        "py_sysctl CLK_EN",
        "clock generator outputs on: [0] core 100 MHz, [1] HDMI TMDS",
        "1 GHz, [2] LVDS 700 MHz, [3] MIPI byte 125 MHz all switched on"))
    result(mem32[SYSCTL + CLK_EN] == CLK_VIDEO_ALL and mem32[SYSCTL + CLK_STATUS] & 1,
           "clocks: display serial clocks enabled, clock generator locked")
    wreg(GPIO0 + G_DIR, mem32[GPIO0 + G_DIR] | CAM_RESET_N | LED_MONO, strings(
        "gpio0 DIR",
        "pin directions (1 = output): [0] camera reset_n and [2] the",
        "monochrome LED become outputs, the other pins keep theirs"))
    wreg(GPIO0 + G_SET, CAM_RESET_N, strings(
        "gpio0 SET",
        "write only (reads 0): the 1 in [0] sets OUT[0], taking the",
        "camera out of reset; the other output pins are unchanged"))
    say("  Camera released from reset (GPIO0[0] = 1)")
    result(camera_set_gap(FRAME_GAP_NS), "camera: frame gap written over I2C 0 (regs 0x20-0x21), read back")
    wreg(VS + VS_K1, 0, strings(
        "vision_system K1",
        "radial distortion coefficient of r^2, Q16.16: 0 = no barrel or",
        "pincushion correction from the r^2 term"))
    wreg(VS + VS_K2, 0, strings(
        "vision_system K2",
        "radial distortion coefficient of r^4, Q16.16: 0 = no r^4 term",
        ""))
    wreg(VS + VS_K3, 0, strings(
        "vision_system K3",
        "radial distortion coefficient of r^6, Q16.16: 0 = no r^6 term;",
        "with K1-K3 all 0 the lens correction is the identity"))
    wreg(VS + VS_CX, 0x8000, strings(
        "vision_system CENTER_X",
        "distortion centre x as a fraction of the width, Q16.16:",
        "0x8000 = 0.5, the centre of the image"))
    wreg(VS + VS_CY, 0x8000, strings(
        "vision_system CENTER_Y",
        "distortion centre y as a fraction of the height, Q16.16:",
        "0x8000 = 0.5, the centre of the image"))
    wreg(VS + VS_SCALE, 0x10000, strings(
        "vision_system SCALE",
        "zoom applied after the correction, Q16.16: 0x10000 = 1.0, no",
        "edge crop, output pixel (x, y) samples input pixel (x, y)"))
    result(frame_size(FRAME_W, FRAME_H), "vision_system: identity correction, 32 x 24 frame")
    result(mem32[FLT + FLT_ID] == BLSH, "blur_sharpen: ID \"BLSH\"; MODE 3 = blur, then sharpen")
    camera_size_set(FRAME_W, FRAME_H)                  # the detectors' frame: the 32 x 24 test images
    tracker_setup()                                    # object_tracker measures every frame (transcript)
    wreg(FLT + FLT_MODE, MODE_BLUR_SHARPEN, strings(
        "blur_sharpen MODE",
        "3 = blur then sharpen: the 5 x 5 blur kernel smooths noise,",
        "then the sharpen kernel restores the edges (0-2, 4 = off)"))
    result(mem32[VP] == VPIP and mem32[VP + VP_BUILD_CFG] & CFG_INSERT,
           "video_pipeline: ID \"VPIP\", insert point built")
    wreg(VP + VP_CTRL, 0, strings(
        "video_pipeline CTRL",
        "0 = pipeline and display stopped while the display timing and",
        "the ISP are programmed"))
    set_format()                                       # ISP set for the image format on GPIO0[30]
    wreg(VP + VP_HACT + 4, 6, strings(
        "video_pipeline H_FP",
        "display horizontal front porch: 6 pixel clocks of blanking",
        "between the last visible pixel and the horizontal sync"))
    wreg(VP + VP_HACT + 8, 10, strings(
        "video_pipeline H_SYNC",
        "display horizontal sync pulse: 10 pixel clocks wide", ""))
    wreg(VP + VP_HACT + 12, 70, strings(
        "video_pipeline H_BP",
        "display horizontal back porch: 70 pixel clocks from the end of",
        "hsync to the first visible pixel (line time for the pipeline)"))
    wreg(VP + VP_HACT + 20, 2, strings(
        "video_pipeline V_FP",
        "display vertical front porch: 2 blank lines after the last",
        "visible line, before the vertical sync"))
    wreg(VP + VP_HACT + 24, 2, strings(
        "video_pipeline V_SYNC",
        "display vertical sync pulse: 2 lines wide", ""))
    wreg(VP + VP_HACT + 28, 3, strings(
        "video_pipeline V_BP",
        "display vertical back porch: 3 blank lines from the end of",
        "vsync to the first visible line"))
    wreg(VP + VP_SYNC_POL, 3, strings(
        "video_pipeline SYNC_POL",
        "[0] hsync and [1] vsync active high (HDMI / CEA timing",
        "polarity for the display)"))
    wreg(VP + VP_START_LEVEL, 16, strings(
        "video_pipeline START_LEVEL",
        "a display frame starts once 16 pixels are buffered: enough",
        "margin that the HDMI output never underflows"))
    wreg(VP + VP_AVI, (2 << 10) | (2 << 8), strings(
        "video_pipeline AVI",
        "HDMI AVI infoframe: [6:0] VIC 0, [9:8] 2 = 16:9 aspect,",
        "[11:10] 2 = full-range RGB; sent to the display every frame"))
    # genlock: each display frame waits for the next corrected frame
    wreg(VP + VP_CTRL, CTRL_ENABLE | CTRL_HDMI | CTRL_LOCK | CTRL_INSERT, strings(
        "video_pipeline CTRL",
        "[0] pipeline on, [1] HDMI output, [3] genlock (each display",
        "frame waits for the next corrected one), [7] insert point on"))
    say("  video_pipeline: 32 x 24 display, HDMI, genlock, insert on")
    say("  Image format: GPIO0[30] = 1 monochrome (ISP bypassed), 0 colour (demosaic RGGB); interrupt on change")
    wreg(GPIO0 + G_INT_STATUS, MONO_SEL | SEQ_ACTIVE, strings(
        "gpio0 INT_STATUS",
        "write 1 to clear: stale edges of [30] image format and [29]",
        "sequence active cleared before their interrupts are enabled"))
    wreg(GPIO0 + G_RISE_EN, MONO_SEL | SEQ_ACTIVE, strings(
        "gpio0 RISE_EN",
        "rising edges of [30] image format (to monochrome) and [29]",
        "(the camera starts an image sequence) set INT_STATUS"))
    wreg(GPIO0 + G_FALL_EN, MONO_SEL, strings(
        "gpio0 FALL_EN",
        "falling edges of [30] (format back to colour) set INT_STATUS;",
        "[29] falling (sequence end) is not an interrupt"))
    wreg(GPIO0 + G_INT_EN, MONO_SEL | SEQ_ACTIVE, strings(
        "gpio0 INT_EN",
        "[30] and [29] drive GPIO0's interrupt (INTC source 6): the",
        "handler reprograms the ISP or notes the sequence start"))
    wreg(INTC + INTC_ENABLE, mem32[INTC + INTC_ENABLE] | IRQ_GPIO0, strings(
        "intc ENABLE",
        "[6] GPIO0 interrupt enabled in the CPU interrupt controller",
        "(the CPU peripherals' sources stay as they were)"))
    result(mem32[FC] == FCNT, "frame_counter: ID \"FCNT\"; end-of-frame interrupts 13 / 14 enabled")
    wreg(FC + FC_EV_EN, 0, strings(
        "frame_counter EV_EN",
        "0 = no channel logged: the event log stays off until an image",
        "sequence is reported (sections 7 and 8)"))
    wreg(FC + FC_CLEAR, EV_ALL, strings(
        "frame_counter CLEAR",
        "write 1s: COUNT0-COUNT4 cleared to 0 (write only, reads 0)", ""))
    wreg(FC + FC_STATUS, 3, strings(
        "frame_counter STATUS",
        "write 1 to clear the [0] first-stage and [1] last-stage",
        "end-of-frame flags: no stale interrupt when they are enabled"))
    wreg(FC + FC_IRQ_EN, 3, strings(
        "frame_counter IRQ_EN",
        "[0] end of frame at the first stage (IRQ 13) and [1] at the",
        "last stage (IRQ 14) raise the frame_counter interrupts"))
    wreg(INTC + INTC_ENABLE, mem32[INTC + INTC_ENABLE] | IRQ_FC_FIRST | IRQ_FC_LAST, strings(
        "intc ENABLE",
        "[13] and [14] frame_counter end-of-frame interrupts enabled:",
        "the handler reads COUNT0 / COUNT1 at every frame"))
    wreg(INTC + INTC_EDGE, IRQ_STATS | IRQ_SOFT, strings(
        "intc EDGE",
        "[12] isp_stats frame done and [15] software source are edge",
        "sources (latched in PENDING); the others are level"))
    wreg(INTC + INTC_PENDING, IRQ_STATS, strings(
        "intc PENDING",
        "write 1 to clear [12]: a statistics edge latched before the",
        "set-up is dropped, frames are counted from the video start"))
    wreg(INTC + INTC_ENABLE, mem32[INTC + INTC_ENABLE] | IRQ_STATS, strings(
        "intc ENABLE",
        "[12] isp_stats frame-done interrupt enabled: one per camera",
        "frame, counted by the handler (frames) for the video start"))
    log_wr = 0


def video_start():
    global stage
    stage = 6
    heading("6. Video start")
    result(camera_stream_on(), "camera: \"stream on\" written over I2C 0 (reg 0x01 = 1)")
    while frames < FRAMES:
        pass
    puts("  ")
    dec(frames)
    say(" statistics interrupts (one per camera frame) received")
    result(mem32[VP + VP_CSI_FRAMES] >= FRAMES, "video_pipeline: CSI-2 frames counted by csi2_rx")
    result(mem32[VS + VS_STATUS] & VS_FRAME_DONE, "vision_system: corrected frame produced")
    st = mem32[FLT + FLT_STATUS]
    result(st & 7 == MODE_BLUR_SHARPEN and st >> 16 != 0, "blur_sharpen: frames filtered in MODE 3")
