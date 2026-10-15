"""video_processor firmware: the video register dump (section 5).

Every register of video_pipeline, its scaler, vision_system, blur_sharpen, frame_counter,
object_tracker and symbol_overlay (objects and texts n = 0-3, in order) with a short description
(dump() in video_init.py); shown at the end of the video set-up with the CPU peripherals (dump_cpu).
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *


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


def dump_video():
    say(" video_pipeline @ 0x10000")
    dump(VP, strings(
        "ID           \"VPIP\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(VP + VP_CTRL, strings(
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
        "BUILD_CFG    interfaces built ([6] insert point)      "), 63)
    say(" scaler (scaler_bilinear) @ 0x14000")
    dump(SCALER, strings(
        "ID           \"BLIN\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(SCALER + 0x10, strings(
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
        "ID           \"VSYS\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(VS + 0x10, strings(
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
        "(reserved)   reads 0 (VERSION is in the ID block)     ",
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
        "ID           \"BLSH\" (ASCII)                           ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(FLT + FLT_MODE, strings(
        "MODE         0 blur 1 sharpen 2 sh->bl 3 bl->sh 4 off ",
        "FRAME_SIZE   [15:0] width [31:16] height              ",
        "BLUR_SHIFT   blur kernel normalisation shift          ",
        "SHARP_SHIFT  sharpen kernel normalisation shift       ",
        "STATUS       [2:0] mode [31:16] frames out            ",
        "INFO         [3:0] N [11:8] COEF_W [23:16] C [31:24]  "), 6)
    say("  0x18250  BLUR_K[0..24]   blur kernel (5 x 5, signed):")
    kernel(FLT + 0x50)
    say("  0x182D0  SHARP_K[0..24]  sharpen kernel (5 x 5, signed):")
    kernel(FLT + 0xD0)
    say(" frame_counter @ 0x18400")
    dump(FC, strings(
        "ID           \"FCNT\" (ASCII)                           ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(FC + FC_IRQ_EN, strings(
        "IRQ_EN       [0] first stage [1] last stage           ",
        "STATUS       marker seen [0] first [1] last ... W1C   ",
        "CLEAR        write 1s: clear COUNT0 .. COUNT4         ",
        "EVENT        oldest event [31] valid [26:24] channel  ",
        "EVENT_TIME   its time, microseconds                   ",
        "EVENT_POP    write 1: remove it                       "), 6)
    dump(FC + FC_COUNT0, strings(
        "COUNT0       frames out of csi2_raw_unpack (first)    ",
        "COUNT1       frames into axis_to_video (last)         ",
        "COUNT2       frames into vision_system                ",
        "COUNT3       frames out of vision_system              ",
        "COUNT4       frames measured by object_tracker        "), 5)
    dump(FC + FC_TIME, strings(
        "TIME         microseconds now                         ",
        "EV_EN        channels logged in the event log         "), 2)
    c = 0
    while c < NTRK:                                    # one detector per object class
        puts(" object_tracker @ ")
        hex32(det_base(c))
        puts(" (")
        class_name(c)
        say(" detector)")
        dump(det_base(c), strings(
            "ID           \"OTRK\" (ASCII)                           ",
            "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
            "DATE         BCD mm/dd/yyyy of that change            "), 3)
        dump(det_base(c) + TRK_CTRL, strings(
            "CTRL         [0] en [1] dark [2] colour [11:8] min run",
            "FRAME_SIZE   [15:0] width [31:16] height              ",
            "THRESH       [7:0] luma threshold                     ",
            "WIN_X        search window [15:0] x0 [31:16] x1       ",
            "WIN_Y        search window [15:0] y0 [31:16] y1       ",
            "FRAMES       frames measured                          ",
            "COUNT        object pixels, last frame                ",
            "BOX_X        object box [15:0] x min [31:16] x max    ",
            "BOX_Y        object box [15:0] y min [31:16] y max    ",
            "SUM_X        sum of the object pixels' x              ",
            "SUM_Y        sum of the object pixels' y              ",
            "STATUS       [0] in frame [1] whole-frame window      ",
            "RUN          run widths [11:0] min [27:16] max        ",
            "Y_RANGE      colour: luma [7:0] min [15:8] max        ",
            "CB_RANGE     colour: Cb [7:0] min [15:8] max          ",
            "CR_RANGE     colour: Cr [7:0] min [15:8] max          ",
            "SAT_MIN      colour: lowest |Cb-128| + |Cr-128|       "), 17)
        c += 1
    puts(" symbol_overlay @ ")
    hex32(OVL)
    nl()
    dump(OVL, strings(
        "ID           \"SOVL\" (ASCII)                           ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(OVL + OVL_CTRL, strings(
        "CTRL         [0] enable                               ",
        "COMMIT       write 1: objects apply at next frame     ",
        "STATUS       [0] commit pending [31:16] frames        ",
        "FRAME_NUM    BCD frame number of the next frame       "), 4)
    j = 0
    while j < 4:
        dump(OVL + OBJ_CTRL + (j << 4), strings(
            "OBJn_CTRL    [0] en [2:1] shape [3] dashed [11:8] w   ",
            "OBJn_X       [15:0] x0 [31:16] x1                     ",
            "OBJn_Y       [15:0] y0 [31:16] y1                     ",
            "OBJn_COLOR   [23:0] pixel {B, G, R}                   "), 4)
        j += 1
    j = 0
    while j < 4:
        dump(OVL + TXT_CTRL + (j << 4), strings(
            "TXTn_CTRL    [0] en [2:1] scale [3] backdrop [4] fnum ",
            "TXTn_POS     [15:0] x [31:16] y                       ",
            "TXTn_COLOR   [23:0] pixel {B, G, R}                   "), 3)
        dump(OVL + TXT_CHARS + (j << 4), strings(
            "TXTn_CHARS0  characters 0-3 (first in [7:0])          ",
            "TXTn_CHARS1  characters 4-7                           ",
            "TXTn_CHARS2  characters 8-11                          ",
            "TXTn_CHARS3  characters 12-15                         "), 4)
        j += 1
