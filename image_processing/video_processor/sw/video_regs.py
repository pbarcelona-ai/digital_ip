"""video_processor firmware: addresses, register offsets and bit values of the video blocks.

Every module of the firmware imports this file (pyc.py inlines it once); the values are
compile-time constants, folded by pyc.py.
"""

# ---------------- clock generator outputs (SYSCTL CLK_EN bits) ----------------
CLK_CORE = 1                       # core logic / pixel clock, 100 MHz
CLK_TMDS = 2                       # HDMI TMDS serial clock, 10x
CLK_LVDS = 4                       # LVDS serial clock, 7x
CLK_MIPI = 8                       # MIPI D-PHY TX byte clock, 125 MHz
CLK_VIDEO_ALL = CLK_CORE | CLK_TMDS | CLK_LVDS | CLK_MIPI

# ---------------- external window (video_processor): src/video_processor_map_pkg.sv ----------------
from video_processor_map_pkg import *   # *_BASE / *_OFFSET of every register window (pyc.py -I src)
VP = VP_BASE                       # video_pipeline (scaler at SCALER_BASE)
SCALER = SCALER_BASE
VS = VS_BASE                       # vision_system
FLT = FLT_BASE                     # blur_sharpen
FC = FC_BASE                       # frame_counter
TRK = TRK_BASE                     # object_tracker detector 0; detector c at TRK + c * TRK_STRIDE (NTRK of them)
OVL = OVL_BASE                     # symbol_overlay

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
SENSOR_SIZE = 0x30                 # camera control registers 0x30-0x33: frame width, height (high, low byte)
SENSOR_DETECT = 0x50               # camera control registers 0x50: object classes to detect (bit c, 0 = pedestrian only),
                                   # 0x51-0x54: box style of class 0-3 (0 dashed box, 1 solid box, 2 dashed circle, 3 solid circle,
                                   # 4 dashed oval, 5 solid oval, 6 solid box in the middle of the target), 0x55: most
                                   # targets tracked at a time (1-12, 0 = 12)
FRAME_GAP_NS = 1280                # end of one frame to the start of the next (camera vertical blanking)

# video registers (video_pipeline: register k at 0x10 + 4 k; blur_sharpen, frame_counter, object_tracker, symbol_overlay: ID block
# 0x00-0x0F (ID, VERSION, DATE, reserved), the rest of each map from 0x10 up)
VP_CTRL = 0x014
VP_BYPASS = 0x018
VP_FRAME_SIZE = 0x024
VP_HACT = 0x09C
VP_SYNC_POL = 0x0BC
VP_START_LEVEL = 0x0C4
VP_AVI = 0x0C8
VP_CSI_FRAMES = 0x0CC
VP_BUILD_CFG = 0x10C
CTRL_ENABLE = 1
CTRL_HDMI = 2
CTRL_LOCK = 8
CTRL_INSERT = 0x80
BYPASS_ALL = 0xFF                  # monochrome: every ISP stage off, raw value on R, G, B
BYPASS_COLOUR = 0xF7               # colour: demosaic (RGGB) on, the rest off
VPIP = 0x56504950
CFG_INSERT = 1 << 6
VS_STATUS = 0x14
VS_WIDTH = 0x18
VS_HEIGHT = 0x1C
VS_K1 = 0x20
VS_K2 = 0x24
VS_K3 = 0x28
VS_CX = 0x2C
VS_CY = 0x30
VS_SCALE = 0x34
VS_FRAME_DONE = 2
VS_RECIP_BUSY = 4
FLT_ID = 0x000
FLT_MODE = 0x014
FLT_FRAME_SIZE = 0x018
FLT_STATUS = 0x024
BLSH = 0x424C5348
MODE_BLUR_SHARPEN = 3
FC_IRQ_EN = 0x18
FC_STATUS = 0x1C
FC_CLEAR = 0x20
FC_EVENT = 0x24                    # oldest logged event: [31] valid [30] overflow [26:24] channel [23:0] count
FC_EVENT_TIME = 0x28               # its time, microseconds
FC_EVENT_POP = 0x2C                # write [0] 1: remove it, [1] 1: clear the overflow flag
FC_COUNT0 = 0x30
FC_COUNT1 = 0x34
FC_TIME = 0x50                     # microseconds now
FC_EV_EN = 0x54                    # channels logged
EV_VALID = 1 << 31
EV_OVERFLOW = 1 << 30
FCNT = 0x46434E54
TRK_CTRL = 0x18                    # object_tracker: [0] enable [1] dark object [2] colour mode [11:8] MIN_RUN
TRK_SIZE = 0x1C
TRK_THRESH = 0x20
TRK_WIN_X = 0x24                   # search window, [15:0] first [31:16] last column
TRK_WIN_Y = 0x28
TRK_FRAMES = 0x2C
TRK_COUNT = 0x30
TRK_BOX_X = 0x34                   # box of the object pixels, [15:0] min [31:16] max
TRK_BOX_Y = 0x38
TRK_RUN = 0x48                     # run widths counted: [11:0] min [27:16] max (0: no limit)
TRK_Y_RANGE = 0x4C                 # colour mode: [7:0] min [15:8] max of Y, Cb, Cr; lowest saturation
TRK_CB_RANGE = 0x50
TRK_CR_RANGE = 0x54
TRK_SAT_MIN = 0x58
TRK_BLOB_CFG = 0x5C                # blobs: [7:0] GAP, [31:16] KEEP (fewest pixels of a blob kept)
TRK_SCRATCH = 0x60                 # 28 CPU scratch words: the tracking state of the detector's class (its tracks)
TRK_RUN_B = 0xD0                   # term B (edges) run widths: [11:0] min [27:16] max
TRK_BLOB_X = 0x100                 # blob i (+ 4 i): box columns [15:0] min [31:16] max, lines, pixels (0: none)
TRK_BLOB_Y = 0x120
TRK_BLOB_N = 0x140
NBLOB = 8                          # blobs per detector (term A 0-3, term B 4-7 with TERM_B)
FEAT_OR = 1                        # CTRL [13:12] FEAT_A: 1 the luma / colour test OR the motion bit
TERM_B = 1 << 14                   # CTRL [14]: term B, the edge bit in runs of RUN_B
FEAT = FEAT_BASE                   # feature_detect: edge and motion bits for every detector
F_CTRL = 0x18                      # [0] on [1] edges [2] motion [3] automatic camera shift [4] restart
F_SIZE = 0x1C
F_EDGE = 0x20                      # [10:0] Sobel threshold [19:16] fill span
F_MOTION = 0x24                    # [7:0] threshold [11:8] fill span [14:12] background rate
FEAT_ID = 0x46454154               # "FEAT"
C_PED = 0                          # object classes = detectors (detector c at TRK + c * TRK_STRIDE)
C_FACE = 1
C_CAR = 2
C_VEH = 3
OTRK = 0x4F54524B
OVL_CTRL = 0x18                    # symbol_overlay: [0] enable
OVL_COMMIT = 0x1C                  # write 1: the object and text registers apply at the next frame start
OVL_FNUM = 0x24                    # frame number (BCD) the next frame shows, then one more per frame
OBJ_CTRL = 0x50                    # object 0: [0] en [2:1] shape [3] dashed [11:8] width [14:12] dash log2
OBJ_X = 0x54
OBJ_Y = 0x58
OBJ_COLOR = 0x5C
TXT_CTRL = 0x110                   # text j at + 16 j: [0] en [2:1] scale log2 [3] backdrop [4] + frame number [12:8] length
TXT_POS = 0x114                    # [15:0] x [31:16] y
TXT_COLOR = 0x118
TXT_CHARS = 0x210                  # text j at + 16 j: 4 words, character k in byte k % 4 of word k / 4
SENSOR_SEQS = 0x56                 # camera control register 0x56: tracking sequences the camera will send (0 = 1)
SENSOR_LOADED = 0x57               # 0x57: number of the sequence whose size, name and options are loaded (1, 2, ...)
SENSOR_NAME = 0x40                 # camera control registers 0x40-0x4F: image name (ASCII, 0 = end)
SOVL = 0x534F564C

# CPU clock cycles (CYCLES register; 200 MHz in the testbench)
