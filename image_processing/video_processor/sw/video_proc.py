"""video_processor firmware, part 2: the video pipeline (the program).

Compiled with ip/cpu/py_core/tools/pyc.py into a flash image (scripts/run_sim.sh
does it; pyc.py inlines video_init.py, the CPU initialisation, at the import
below); the py_soc boot loader copies it from SPI flash at reset. Every step
is reported on UART 0 as readable text (the testbench saves it to
cpu_bootup.txt):

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
     counter and statistics interrupts.
     The camera image format comes from the GPIO0[30] input (1 = monochrome:
     every ISP stage bypassed, the raw value on R, G and B; 0 = colour: RGGB
     demosaic on). An interrupt on either edge reprograms the ISP BYPASS
     register (set_format, applied by the ISP at the next frame start) and
     GPIO0[2] shows the format programmed.
  5. Video register dump: video_pipeline, its scaler, vision_system,
     blur_sharpen and frame_counter, with a short description (skipped when
     the GPIO0[31] strap is high: quick simulation).
  6. Video start: camera "stream on" over I2C 0, frames, checks.
  7. Frame counters and image sequence: frame_counter counts the ends of
     frame of the first pipeline stage (csi2_raw_unpack, interrupt 13,
     COUNT0) and of the last one (into axis_to_video, interrupt 14, COUNT1);
     the interrupt handler reads the respective counter at each one. Once
     the pipeline is idle both counters are cleared, so the image sequence
     (GPIO0[29] = 1; the frames follow each other at least the programmed
     frame gap apart) is counted from 0: the end of its first frame makes a count 1.
     Every end of frame is reported on UART 0 as its own line, counts 1, 2,
     3, ... at each stage (frames that end faster than a line of text are
     reported right after).
  8. Summary and "END OF REPORT".

Text lives in a string table in flash (pyc.py: a string literal is a handle);
puts() reads it through the flash controller. The testbench watches the
`stage`, `errors` and `frames` globals: stage 3 = CPU initialised, 100 = video
running, 160 = frame-count report, 161 = waiting for the image sequence, 200 = done.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_init import *           # CPU initialisation, UART text output (pyc.py inlines it)

# ---------------- clock generator outputs (SYSCTL CLK_EN bits) ----------------
CLK_CORE = 1                       # core logic / pixel clock, 100 MHz
CLK_TMDS = 2                       # HDMI TMDS serial clock, 10x
CLK_LVDS = 4                       # LVDS serial clock, 7x
CLK_MIPI = 8                       # MIPI D-PHY TX byte clock, 125 MHz
CLK_VIDEO_ALL = CLK_CORE | CLK_TMDS | CLK_LVDS | CLK_MIPI

# ---------------- external window (video_processor) ----------------
VP = 0x10000                       # video_pipeline (scaler at +0x4000)
SCALER = 0x14000
VS = 0x18000                       # vision_system
FLT = 0x18200                      # blur_sharpen
FC = 0x18400                       # frame_counter

# interrupts of the video system
IRQ_GPIO0 = 1 << 6                 # image format pin
IRQ_STATS = 1 << 12                # isp_stats frame done (edge)
IRQ_FC_FIRST = 1 << 13             # end of frame at the first pipeline stage (level, frame_counter STATUS[0])
IRQ_FC_LAST = 1 << 14              # end of frame at the last pipeline stage (level, frame_counter STATUS[1])

# GPIO0 pins of the camera board
CAM_RESET_N = 1 << 0               # output: camera out of reset
LED_MONO = 1 << 2                  # output: monochrome format programmed
SEQ_ACTIVE = 1 << 29               # input: the camera has an image sequence to send
MONO_SEL = 1 << 30                 # input: camera image format, 1 = monochrome
SENSOR_STREAM = 0x01               # camera control register: 1 = stream on
SENSOR_GAP = 0x20                  # camera control registers 0x20-0x21: frame gap in ns (high, low byte)
FRAME_GAP_NS = 1280                # end of one frame to the start of the next (camera vertical blanking)

# video registers
VP_CTRL = 0x004
VP_BYPASS = 0x008
VP_FRAME_SIZE = 0x014
VP_HACT = 0x08C
VP_SYNC_POL = 0x0AC
VP_START_LEVEL = 0x0B4
VP_AVI = 0x0B8
VP_CSI_FRAMES = 0x0BC
VP_BUILD_CFG = 0x0FC
CTRL_ENABLE = 1
CTRL_HDMI = 2
CTRL_LOCK = 8
CTRL_INSERT = 0x80
BYPASS_ALL = 0xFF                  # monochrome: every ISP stage off, raw value on R, G, B
BYPASS_COLOUR = 0xF7               # colour: demosaic (RGGB) on, the rest off
VPIP = 0x56504950
CFG_INSERT = 1 << 6
VS_STATUS = 0x04
VS_WIDTH = 0x08
VS_HEIGHT = 0x0C
VS_K1 = 0x10
VS_K2 = 0x14
VS_K3 = 0x18
VS_CX = 0x1C
VS_CY = 0x20
VS_SCALE = 0x24
VS_FRAME_DONE = 2
VS_RECIP_BUSY = 4
FLT_ID = 0x000
FLT_MODE = 0x004
FLT_FRAME_SIZE = 0x008
FLT_STATUS = 0x014
BLSH = 0x424C5348
MODE_BLUR_SHARPEN = 3
FC_IRQ_EN = 0x08
FC_STATUS = 0x0C
FC_CLEAR = 0x10
FC_COUNT0 = 0x20
FC_COUNT1 = 0x24
FCNT = 0x46434E54

FRAME_W = 32
FRAME_H = 24
FRAMES = 6
# CPU clock cycles (CYCLES register; 200 MHz in the testbench)
SEQ_WAIT = 16000000                # 80 ms: wait for the camera's image sequence
QUIET = 100000                     # 0.5 ms without an end of frame: the pipeline is empty

# ---------------- state (globals) ----------------
frames = 0                         # isp_stats interrupts
fmt_cnt = 0                        # image format changes programmed
fc_first = 0                       # frame_counter COUNT0, read at its last end-of-frame interrupt
fc_last = 0                        # frame_counter COUNT1, read at its last end-of-frame interrupt
fc_new = 0                         # [0] first-stage, [1] last-stage end of frame since cleared
seq_seen = 0                       # GPIO0[29] rising edge seen: the camera started its image sequence
seq_first = 0                      # COUNT0 / COUNT1 read when the sequence started
seq_last = 0


def kernel(base):
    """A 5 x 5 signed kernel as a grid."""
    r = 0
    while r < 5:
        puts("      ")
        c = 0
        while c < 5:
            v = signed32(mem32[base + (((r << 2) + r + c) << 2)])
            if v >= 0:
                putc(32)
            dec(v)
            putc(9)
            c += 1
        nl()
        r += 1


# ======================================================================= interrupts

def set_format():
    """Program the ISP for the camera image format on GPIO0[30]; GPIO0[2] shows the result."""
    global fmt_cnt
    if mem32[GPIO0 + G_IN] & MONO_SEL:
        mem32[VP + VP_BYPASS] = BYPASS_ALL
        mem32[GPIO0 + G_SET] = LED_MONO
    else:
        mem32[VP + VP_BYPASS] = BYPASS_COLOUR
        mem32[GPIO0 + G_CLEAR] = LED_MONO
    fmt_cnt += 1


def isr():
    global frames, fc_first, fc_last, fc_new, seq_seen, seq_first, seq_last
    pending = mem32[INTC + INTC_MASKED]
    if pending & IRQ_GPIO0:                             # first: the next frame follows within the frame gap
        s = mem32[GPIO0 + G_INT_STATUS]
        mem32[GPIO0 + G_INT_STATUS] = s                 # write 1 to clear
        if s & MONO_SEL:
            set_format()                                # image format pin changed
        if s & SEQ_ACTIVE:                              # image sequence starts: note the counts now
            seq_seen = 1
            seq_first = mem32[FC + FC_COUNT0]
            seq_last = mem32[FC + FC_COUNT1]
    if pending & IRQ_FC_FIRST:                          # end of frame, first stage: read its counter
        fc_first = mem32[FC + FC_COUNT0]
        fc_new = fc_new | 1
        mem32[FC + FC_STATUS] = 1                       # write 1 to clear (level source)
    if pending & IRQ_FC_LAST:                           # end of frame, last stage: read its counter
        fc_last = mem32[FC + FC_COUNT1]
        fc_new = fc_new | 2
        mem32[FC + FC_STATUS] = 2
    if pending & IRQ_STATS:
        frames += 1
        mem32[INTC + INTC_PENDING] = IRQ_STATS          # edge source: write 1 to clear
    cpu_isr(pending)                                    # software, GPIO2, watchdog (video_init.py)


# ======================================================================= 4. video set-up

def camera_reg(reg, n, rd):
    """I2C 0 transfer to the camera's control registers: the register pointer, then n data bytes
    already queued (write) or n bytes to read (rd = I_READ)."""
    if rd:
        mem32[I2C0 + DPORT + TXDATA] = reg
        return i2c_go(I2C0, SENSOR_ADDR, 1, 0) and i2c_go(I2C0, SENSOR_ADDR, n, I_READ)
    return i2c_go(I2C0, SENSOR_ADDR, n + 1, 0)


def video_setup():
    """Program every video register after the CPU initialisation; the camera is not streaming yet."""
    global stage
    stage = 4
    heading("4. Video set-up (CPU initialisation complete, camera not streaming)")
    mem32[SYSCTL + CLK_EN] = CLK_VIDEO_ALL             # display serial clocks on (core / MIPI clocks run from reset)
    say("  Clocks: core 100 MHz, HDMI TMDS 1 GHz, LVDS 700 MHz, MIPI byte 125 MHz (SYSCTL CLK_EN)")
    result(mem32[SYSCTL + CLK_EN] == CLK_VIDEO_ALL and mem32[SYSCTL + CLK_STATUS] & 1,
           "clocks: display serial clocks enabled, clock generator locked")
    mem32[GPIO0 + G_DIR] = mem32[GPIO0 + G_DIR] | CAM_RESET_N | LED_MONO
    mem32[GPIO0 + G_SET] = CAM_RESET_N
    say("  Camera released from reset (GPIO0[0] = 1)")
    mem32[I2C0 + DPORT + TXDATA] = SENSOR_GAP          # frame gap, high byte first
    mem32[I2C0 + DPORT + TXDATA] = FRAME_GAP_NS >> 8
    mem32[I2C0 + DPORT + TXDATA] = FRAME_GAP_NS & 255
    ok = camera_reg(SENSOR_GAP, 2, 0)
    ok = ok and camera_reg(SENSOR_GAP, 2, I_READ)
    gap = ((rx_word(I2C0) & 255) << 8) | (rx_word(I2C0) & 255)
    puts("  Camera frame gap (end of one frame to the start of the next): ")
    dec(gap)
    say(" ns")
    result(ok and gap == FRAME_GAP_NS, "camera: frame gap written over I2C 0 (regs 0x20-0x21), read back")
    mem32[VS + VS_WIDTH] = FRAME_W
    mem32[VS + VS_HEIGHT] = FRAME_H
    mem32[VS + VS_K1] = 0
    mem32[VS + VS_K2] = 0
    mem32[VS + VS_K3] = 0
    mem32[VS + VS_CX] = 0x8000
    mem32[VS + VS_CY] = 0x8000
    mem32[VS + VS_SCALE] = 0x10000
    result(wait_clear(VS + VS_STATUS, VS_RECIP_BUSY), "vision_system: identity correction, 32 x 24 frame")
    result(mem32[FLT + FLT_ID] == BLSH, "blur_sharpen: ID \"BLSH\"; MODE 3 = blur, then sharpen")
    mem32[FLT + FLT_FRAME_SIZE] = (FRAME_H << 16) | FRAME_W
    mem32[FLT + FLT_MODE] = MODE_BLUR_SHARPEN
    result(mem32[VP] == VPIP and mem32[VP + VP_BUILD_CFG] & CFG_INSERT,
           "video_pipeline: ID \"VPIP\", insert point built")
    mem32[VP + VP_CTRL] = 0
    set_format()                                       # ISP set for the image format on GPIO0[30]
    mem32[VP + VP_FRAME_SIZE] = (FRAME_H << 16) | FRAME_W
    mem32[VP + VP_HACT] = FRAME_W                      # h: active, front porch, sync, back porch
    mem32[VP + VP_HACT + 4] = 6
    mem32[VP + VP_HACT + 8] = 10
    mem32[VP + VP_HACT + 12] = 70
    mem32[VP + VP_HACT + 16] = FRAME_H                 # v: active, front porch, sync, back porch
    mem32[VP + VP_HACT + 20] = 2
    mem32[VP + VP_HACT + 24] = 2
    mem32[VP + VP_HACT + 28] = 3
    mem32[VP + VP_SYNC_POL] = 3
    mem32[VP + VP_START_LEVEL] = 16
    mem32[VP + VP_AVI] = (2 << 10) | (2 << 8)
    # genlock: each display frame waits for the next corrected frame
    mem32[VP + VP_CTRL] = CTRL_ENABLE | CTRL_HDMI | CTRL_LOCK | CTRL_INSERT
    say("  video_pipeline: 32 x 24 display, HDMI, genlock, insert on")
    say("  Image format: GPIO0[30] = 1 monochrome (ISP bypassed), 0 colour (demosaic RGGB); interrupt on change")
    mem32[GPIO0 + G_INT_STATUS] = MONO_SEL | SEQ_ACTIVE
    mem32[GPIO0 + G_RISE_EN] = MONO_SEL | SEQ_ACTIVE   # SEQ_ACTIVE: rising edge only (sequence start)
    mem32[GPIO0 + G_FALL_EN] = MONO_SEL
    mem32[GPIO0 + G_INT_EN] = MONO_SEL | SEQ_ACTIVE
    mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] | IRQ_GPIO0
    result(mem32[FC] == FCNT, "frame_counter: ID \"FCNT\"; end-of-frame interrupts 13 / 14 enabled")
    mem32[FC + FC_CLEAR] = 3
    mem32[FC + FC_STATUS] = 3
    mem32[FC + FC_IRQ_EN] = 3
    mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] | IRQ_FC_FIRST | IRQ_FC_LAST
    mem32[INTC + INTC_EDGE] = IRQ_STATS | IRQ_SOFT
    mem32[INTC + INTC_PENDING] = IRQ_STATS
    mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] | IRQ_STATS


# ======================================================================= 6. video start

def video_start():
    global stage
    stage = 6
    heading("6. Video start")
    mem32[I2C0 + DPORT + TXDATA] = SENSOR_STREAM
    mem32[I2C0 + DPORT + TXDATA] = 1
    result(i2c_go(I2C0, SENSOR_ADDR, 2, 0), "camera: \"stream on\" written over I2C 0 (reg 0x01 = 1)")
    while frames < FRAMES:
        pass
    puts("  ")
    dec(frames)
    say(" statistics interrupts (one per camera frame) received")
    result(mem32[VP + VP_CSI_FRAMES] >= FRAMES, "video_pipeline: CSI-2 frames counted by csi2_rx")
    result(mem32[VS + VS_STATUS] & VS_FRAME_DONE, "vision_system: corrected frame produced")
    st = mem32[FLT + FLT_STATUS]
    result(st & 7 == MODE_BLUR_SHARPEN and st >> 16 != 0, "blur_sharpen: frames filtered in MODE 3")


# ======================================================================= 5. video register dump

def dump_video():
    say(" video_pipeline @ 0x10000")
    dump(VP, strings(
        "ID           \"VPIP\"                                   ",
        "CTRL         [0] en [1] HDMI [2] TPG [3] lock [7] ins ",
        "BYPASS       [0] BLC [1] WB [2] DPC .. [7] scaler     ",
        "STATUS       [0] output locked to the camera          ",
        "CSI          [5:0] data type [7:6] virtual channel    ",
        "FRAME_SIZE   [15:0] width [31:16] height              ",
        "BLC_R        black level, R                           ",
        "BLC_GR       black level, Gr                          ",
        "BLC_GB       black level, Gb                          ",
        "BLC_B        black level, B                           ",
        "WB_R         white balance gain R, Q4.8               ",
        "WB_G         white balance gain G, Q4.8               ",
        "WB_B         white balance gain B, Q4.8               ",
        "DPC_THR      defect pixel threshold                   ",
        "CCM_C00      colour matrix, Q5.10                     ",
        "CCM_C01      colour matrix, Q5.10                     ",
        "CCM_C02      colour matrix, Q5.10                     ",
        "CCM_C10      colour matrix, Q5.10                     ",
        "CCM_C11      colour matrix, Q5.10                     ",
        "CCM_C12      colour matrix, Q5.10                     ",
        "CCM_C20      colour matrix, Q5.10                     ",
        "CCM_C21      colour matrix, Q5.10                     ",
        "CCM_C22      colour matrix, Q5.10                     ",
        "CCM_OFF_R    colour matrix offset R                   ",
        "CCM_OFF_G    colour matrix offset G                   ",
        "CCM_OFF_B    colour matrix offset B                   ",
        "GAMMA_ADDR   gamma table write index                  ",
        "GAMMA_DATA   gamma table data (write)                 ",
        "STAT_THR     statistics clip threshold                ",
        "STAT_SUM_R   statistics: sum of R, last frame         ",
        "STAT_SUM_G   statistics: sum of G, last frame         ",
        "STAT_SUM_B   statistics: sum of B, last frame         ",
        "STAT_PIX     statistics: pixels, last frame           ",
        "STAT_CLIP    statistics: clipped pixels               ",
        "STAT_FRAMES  statistics: frames                       ",
        "H_ACTIVE     display: active pixels per line          ",
        "H_FP         display: horizontal front porch          ",
        "H_SYNC       display: horizontal sync width           ",
        "H_BP         display: horizontal back porch           ",
        "V_ACTIVE     display: active lines                    ",
        "V_FP         display: vertical front porch            ",
        "V_SYNC       display: vertical sync width             ",
        "V_BP         display: vertical back porch             ",
        "SYNC_POL     [0] hsync [1] vsync active high          ",
        "LOCK_MAX     genlock: max extra blanking lines        ",
        "START_LEVEL  pixels buffered before a frame starts    ",
        "AVI          HDMI AVI: VIC, aspect, RGB range         ",
        "CSI_FRAMES   camera frames received                   ",
        "ECC_CORR     CSI-2 header ECC corrections             ",
        "ECC_ERR      CSI-2 header ECC errors                  ",
        "CRC_ERR      CSI-2 payload CRC errors                 ",
        "UNDERFLOWS   display underflows                       ",
        "DPC_CORR     defective pixels corrected               ",
        "CSI_OVERFLOW CSI words lost (FIFO full)               ",
        "OUT_CTRL     LVDS / DSI / CSI-2 TX output options     ",
        "DSI_GAPS     DSI LP gaps                              ",
        "CSITX_GAP    CSI-2 TX gap between packets             ",
        "DSI_CMD      DSI command queue (write)                ",
        "DSI_CMD_BYTE DSI command payload byte (write)         ",
        "TX_STATUS    [0] DSI command queue busy               ",
        "DSI_DROPS    lines DSI could not send                 ",
        "CSITX_DROPS  lines CSI-2 TX could not send            ",
        "CSITX_FRAMES frames sent by CSI-2 TX                  ",
        "BUILD_CFG    interfaces built ([6] insert point)      "), 64)
    say(" scaler (scaler_bilinear) @ 0x14000")
    dump(SCALER, strings(
        "CTRL         [0] enable                               ",
        "STATUS       [0] busy [1] frame done [5] generating   ",
        "IN_SIZE      [15:0] width [31:16] height              ",
        "OUT_SIZE     [15:0] width [31:16] height              ",
        "STEP_X       source pixels per output pixel, 16.16    ",
        "STEP_Y       source lines per output line, 16.16      ",
        "OFFS_X       start position x, 16.16                  ",
        "OFFS_Y       start position y, 16.16                  ",
        "FRAME_CNT    frames completed                         ",
        "IP_ID        ASCII IP tag                             ",
        "CAPS         capability word                          ",
        "MAX_SIZE     [15:0] MAX_W [31:16] MAX_H               "), 12)
    say(" vision_system @ 0x18000")
    dump(VS, strings(
        "CTRL         [0] soft reset (self-clearing)           ",
        "STATUS       [0] busy [1] frame done [2] recip busy   ",
        "IMG_WIDTH    frame width                              ",
        "IMG_HEIGHT   frame height                             ",
        "K1           radial coefficient r^2, Q16.16           ",
        "K2           radial coefficient r^4, Q16.16           ",
        "K3           radial coefficient r^6, Q16.16           ",
        "CENTER_X     centre, fraction of width, Q16.16        ",
        "CENTER_Y     centre, fraction of height, Q16.16       ",
        "SCALE        edge-crop zoom, Q16.16                   ",
        "VERSION      vision_system version                    ",
        "INTERP_MODE  [0] 0 bilinear, 1 bicubic                ",
        "CALIB_MODE   [0] 1 = direct camera calibration        ",
        "FX           focal length x, pixels Q16.16            ",
        "FY           focal length y, pixels Q16.16            ",
        "CX           principal point x, pixels Q16.16         ",
        "CY           principal point y, pixels Q16.16         ",
        "P1           tangential coefficient 1, Q16.16         ",
        "P2           tangential coefficient 2, Q16.16         ",
        "MODEL_SEL    0 radial 1 fisheye 3 persp. 5 panoramic  ",
        "H11          homography, Q16.16                       ",
        "H12          homography, Q16.16                       ",
        "H13          homography translation, pixels           ",
        "H21          homography, Q16.16                       ",
        "H22          homography, Q16.16                       ",
        "H23          homography translation, pixels           ",
        "H31          homography, Q16.16                       ",
        "H32          homography, Q16.16                       "), 28)
    say(" blur_sharpen @ 0x18200")
    dump(FLT, strings(
        "ID           \"BLSH\"                                   ",
        "MODE         0 blur 1 sharpen 2 sh->bl 3 bl->sh 4 off ",
        "FRAME_SIZE   [15:0] width [31:16] height              ",
        "BLUR_SHIFT   blur kernel normalisation shift          ",
        "SHARP_SHIFT  sharpen kernel normalisation shift       ",
        "STATUS       [2:0] mode [31:16] frames out            ",
        "INFO         [3:0] N [11:8] COEF_W [23:16] C [31:24]  "), 7)
    say("  +0x040  BLUR_K[0..24]   blur kernel (5 x 5, signed):")
    kernel(FLT + 0x40)
    say("  +0x0C0  SHARP_K[0..24]  sharpen kernel (5 x 5, signed):")
    kernel(FLT + 0xC0)
    say(" frame_counter @ 0x18400")
    dump(FC, strings(
        "ID           \"FCNT\"                                   ",
        "VERSION      frame_counter version                    ",
        "IRQ_EN       [0] first stage [1] last stage           ",
        "STATUS       end of frame seen [0] first [1] last W1C ",
        "CLEAR        write 1s: clear COUNT0 / COUNT1          "), 5)
    dump(FC + FC_COUNT0, strings(
        "COUNT0       frames out of csi2_raw_unpack (first)    ",
        "COUNT1       frames into axis_to_video (last)         "), 2)


# ======================================================================= 7. frame counters, image sequence

def now():
    return mem32[SYSCTL + CYCLES]


def frame_sequence():
    global stage, fc_new, fc_first, fc_last
    stage = 160
    heading("7. Frame counters and image sequence")
    say("  frame_counter @ 0x18400 counts the end of every frame:")
    say("    COUNT0  first pipeline stage (csi2_raw_unpack output), interrupt 13")
    say("    COUNT1  last pipeline stage (axis_to_video input), interrupt 14")
    say("  The interrupt handler reads the respective counter at each end of frame;")
    say("  a rising edge on GPIO0[29] (interrupt) marks the start of the camera's image sequence.")
    puts("  Counted so far (live camera frames): first stage ")
    dec(fc_first)
    puts(", last stage ")
    dec(fc_last)
    nl()
    # wait until the pipeline is empty (no end of frame for QUIET), then clear both counters:
    # the sequence is counted from 0, the end of its first frame makes a count 1
    c0 = mem32[FC + FC_COUNT0]
    c1 = mem32[FC + FC_COUNT1]
    t0 = now()
    while now() - t0 < QUIET:
        n0 = mem32[FC + FC_COUNT0]
        n1 = mem32[FC + FC_COUNT1]
        if n0 != c0 or n1 != c1:
            c0 = n0
            c1 = n1
            t0 = now()
    irq_disable()
    mem32[FC + FC_CLEAR] = 3
    fc_first = 0
    fc_last = 0
    fc_new = 0
    irq_enable()
    result(mem32[FC + FC_COUNT0] == 0 and mem32[FC + FC_COUNT1] == 0,
           "FRAME_CNT: pipeline idle, both counters cleared before the image sequence")
    # the start of the sequence is latched by the GPIO0 interrupt (it may be short and over
    # before this point is reached); the counts at its start come from the handler too
    stage = 161                                        # listening for the image sequence
    t0 = now()
    while not seq_seen and now() - t0 < SEQ_WAIT:
        pass
    if not seq_seen:
        say("  No image sequence (GPIO0[29] stayed low)")
        return
    puts("  Image sequence (GPIO0[29] rose), frames ")
    dec(FRAME_GAP_NS)
    puts(" ns or more apart; counts at its start: first stage ")
    dec(seq_first)
    puts(", last stage ")
    dec(seq_last)
    nl()
    first0 = seq_first
    last0 = seq_last
    # one line per end of frame: every count from the last one reported up to the one the handler
    # read (the counters only advance at an end of frame, so each count is one frame; several frames
    # can end while a line is being sent)
    pf = first0
    pl = last0
    t0 = now()
    seq = 1
    while seq or now() - t0 < QUIET:                   # until the sequence ended and the pipeline is empty
        irq_disable()
        ev = fc_new
        fc_new = 0
        f = fc_first
        l = fc_last
        irq_enable()
        while pf < f:
            pf += 1
            puts("  EOF first stage (interrupt 13): frame count ")
            dec(pf)
            nl()
        while pl < l:
            pl += 1
            puts("  EOF last stage  (interrupt 14): frame count ")
            dec(pl)
            nl()
        if ev:
            t0 = now()
        if seq and not mem32[GPIO0 + G_IN] & SEQ_ACTIVE:
            seq = 0
            t0 = now()
    puts("  Sequence: ")
    dec(fc_first - first0)
    puts(" frames counted at the first stage, ")
    dec(fc_last - last0)
    say(" at the last stage")
    if fc_last - last0 < fc_first - first0:
        say("  (vs_stream_adapter drops frames that arrive while vision_system is busy: a longer gap passes more)")
    result(first0 == 0 and last0 == 0 and fc_first > 0 and fc_last > 0,
           "FRAME_CNT: counts start at 0, each end of frame adds 1 at the first and the last stage")


# ======================================================================= main

def main():
    global stage
    start = mem32[SYSCTL + CYCLES]
    irq_handler(isr)
    if cpu_init(start):                                # sections 1-3 (video_init.py); core logic released
        video_setup()                                  # section 4
        stage = 5
        heading("5. Video register dump (offset  name  description  value)")
        if mem32[GPIO0 + G_IN] & QUICK_STRAP:
            say(" (skipped: GPIO0[31] quick-simulation strap)")
        else:
            dump_video()
        video_start()                                  # section 6
        if errors == 0:
            mem32[GPIO0 + G_SET] = LED_RUN
        stage = 100                                    # video running: the testbench checks the outputs
        frame_sequence()                               # section 7
    heading("8. Summary")
    puts("  ")
    dec(passes)
    puts(" checks passed, ")
    dec(errors)
    say(" failed")
    if errors == 0:
        say("  System ready: camera -> ISP -> vision_system -> blur_sharpen -> HDMI / LVDS")
    else:
        say("  SYSTEM NOT READY: see the [FAIL] lines above")
    say("END OF REPORT")
    wait_set(UART0 + DPORT + PSTATUS, TX_EMPTY)
    wait_clear(UART0 + U_STATUS, 1)
    stage = 200


main()
while True:
    pass
