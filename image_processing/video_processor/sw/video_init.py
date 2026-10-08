"""video_processor start-up firmware for the py_soc control CPU.

Compiled with ip/cpu/py_core/tools/pyc.py into a flash image (make fw); the
py_soc boot loader copies it from SPI flash at reset. It brings the video
system up the way a product would:
  1. GPIO0[0] releases the camera reset (GPIO0[1] is the "video running" LED)
  2. vision_system: identity correction for a FRAME_W x FRAME_H frame;
     blur_sharpen: blur, then sharpen (MODE 3)
  3. video_pipeline: ISP set-up, display timing, insert point -> vision_system
  4. isp_stats frame-done interrupt (intc source 12, edge)
  5. camera: "stream on" over I2C 0 (sensor at SENSOR_ADDR, register 0x01)
  6. wait for frames (counted by the interrupt handler), check status, LED on
The testbench watches the `stage`, `errors` and `frames` globals.
"""
from machine import mem32          # ignored by pyc: mem32 is native

# ---------------- py_soc address map ----------------
INTC = 0x1000
GPIO0 = 0x3000
I2C0 = 0x8000
I2C0_D = I2C0 + 0x100
# external window (video_processor)
VP = 0x10000                       # video_pipeline
VS = 0x18000                       # vision_system
FLT = 0x18200                      # blur_sharpen

# interrupt controller
INTC_ENABLE = 0x00
INTC_EDGE = 0x04
INTC_PENDING = 0x0C
INTC_MASKED = 0x18
IRQ_STATS = 1 << 12

# GPIO
G_OUT = 0x00
G_DIR = 0x04
G_SET = 0x0C
CAM_RESET_N = 1 << 0
LED_RUN = 1 << 1

# I2C
I_CTRL = 0x00
I_ADDR = 0x04
I_LEN = 0x08
I_STATUS = 0x10
I_EN = 1
I_START = 2
I_DONE = 2
I_NACK = 4
I_CLEAR = 0xE
TXDATA = 0x00
SENSOR_ADDR = 0x36
SENSOR_STREAM = 0x01

# video_pipeline registers
VP_ID = 0x000
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
BYPASS_ALL = 0xFF                  # raw sensor data, grey, no scaler
VPIP = 0x56504950
CFG_INSERT = 1 << 6

# vision_system registers
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

# blur_sharpen registers
FLT_ID = 0x000
FLT_MODE = 0x004
FLT_FRAME_SIZE = 0x008
FLT_STATUS = 0x014
BLSH = 0x424C5348
MODE_BLUR_SHARPEN = 3
VS_RECIP_BUSY = 4

FRAME_W = 32
FRAME_H = 24
FRAMES = 6
TMO = 20000

# ---------------- state ----------------
errors = 0
stage = 0
frames = 0


def wait_set(addr, mask):
    t = 0
    while not mem32[addr] & mask and t < TMO:
        t += 1
    return t < TMO


def wait_clear(addr, mask):
    t = 0
    while mem32[addr] & mask and t < TMO:
        t += 1
    return t < TMO


def isr():
    global frames
    pending = mem32[INTC + INTC_MASKED]
    if pending & IRQ_STATS:
        frames += 1
        mem32[INTC + INTC_PENDING] = IRQ_STATS     # edge source: write 1 to clear


# 1. camera out of reset, LED off
stage = 1
mem32[GPIO0 + G_OUT] = 0
mem32[GPIO0 + G_DIR] = CAM_RESET_N | LED_RUN
mem32[GPIO0 + G_SET] = CAM_RESET_N

# 2. vision_system: identity correction (k = 0, centre 0.5, scale 1.0)
stage = 2
mem32[VS + VS_WIDTH] = FRAME_W
mem32[VS + VS_HEIGHT] = FRAME_H
mem32[VS + VS_K1] = 0
mem32[VS + VS_K2] = 0
mem32[VS + VS_K3] = 0
mem32[VS + VS_CX] = 0x8000
mem32[VS + VS_CY] = 0x8000
mem32[VS + VS_SCALE] = 0x10000
if not wait_clear(VS + VS_STATUS, VS_RECIP_BUSY):
    errors += 1
if mem32[FLT + FLT_ID] != BLSH:
    errors += 1
mem32[FLT + FLT_FRAME_SIZE] = (FRAME_H << 16) | FRAME_W
mem32[FLT + FLT_MODE] = MODE_BLUR_SHARPEN

# 3. video_pipeline
stage = 3
if mem32[VP + VP_ID] != VPIP:
    errors += 1
if not mem32[VP + VP_BUILD_CFG] & CFG_INSERT:
    errors += 1
mem32[VP + VP_CTRL] = 0
mem32[VP + VP_BYPASS] = BYPASS_ALL
mem32[VP + VP_FRAME_SIZE] = (FRAME_H << 16) | FRAME_W
mem32[VP + VP_HACT] = FRAME_W                   # h: active, front porch, sync, back porch
mem32[VP + VP_HACT + 4] = 6
mem32[VP + VP_HACT + 8] = 10
mem32[VP + VP_HACT + 12] = 70
mem32[VP + VP_HACT + 16] = FRAME_H             # v: active, front porch, sync, back porch
mem32[VP + VP_HACT + 20] = 2
mem32[VP + VP_HACT + 24] = 2
mem32[VP + VP_HACT + 28] = 3
mem32[VP + VP_SYNC_POL] = 3
mem32[VP + VP_START_LEVEL] = 16
mem32[VP + VP_AVI] = (2 << 10) | (2 << 8)
# genlock: each display frame waits (in vertical blanking) for the next
# corrected frame, so the display follows vision_system's output rate
mem32[VP + VP_CTRL] = CTRL_ENABLE | CTRL_HDMI | CTRL_LOCK | CTRL_INSERT

# 4. statistics interrupt
stage = 4
mem32[INTC + INTC_EDGE] = IRQ_STATS
mem32[INTC + INTC_PENDING] = IRQ_STATS
mem32[INTC + INTC_ENABLE] = IRQ_STATS
irq_handler(isr)
irq_enable()

# 5. camera: stream on
stage = 5
mem32[I2C0_D + TXDATA] = SENSOR_STREAM
mem32[I2C0_D + TXDATA] = 1
mem32[I2C0 + I_ADDR] = SENSOR_ADDR
mem32[I2C0 + I_LEN] = 2
mem32[I2C0 + I_STATUS] = I_CLEAR
mem32[I2C0 + I_CTRL] = I_EN | I_START
if not wait_set(I2C0 + I_STATUS, I_DONE):
    errors += 1
if mem32[I2C0 + I_STATUS] & I_NACK:
    errors += 1

# 6. frames arrive: check, then switch the LED on
stage = 6
while frames < FRAMES:
    pass
if mem32[VP + VP_CSI_FRAMES] < FRAMES:
    errors += 1
if not mem32[VS + VS_STATUS] & VS_FRAME_DONE:
    errors += 1
if mem32[FLT + FLT_STATUS] & 7 != MODE_BLUR_SHARPEN:
    errors += 1
if mem32[FLT + FLT_STATUS] >> 16 == 0:     # frames filtered
    errors += 1
if errors == 0:
    mem32[GPIO0 + G_SET] = LED_RUN
stage = 100
while True:
    pass
