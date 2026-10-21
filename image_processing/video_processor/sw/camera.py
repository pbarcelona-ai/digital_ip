"""video_processor firmware: the camera module.

Camera control over I2C 0 (CCI registers of the sensor at SENSOR_ADDR): the frame gap, the frame
size, the image name and the detection options (classes, symbol styles) of the tracking sequence and
"stream on"; the image format pin GPIO0[30] and the ISP set for it.
"""
from machine import mem32          # ignored by pyc: mem32 is native
from video_regs import *

cam_w = 128                        # frame size read from the camera (registers 0x30-0x33)
cam_h = 96
fmt_cnt = 0                        # image format changes programmed


def camera_reg(reg, n, rd):
    """I2C 0 transfer to the camera's control registers: the register pointer, then n data bytes
    already queued (write) or n bytes to read (rd = I_READ)."""
    if rd:
        mem32[I2C0 + DPORT + TXDATA] = reg
        return i2c_go(I2C0, SENSOR_ADDR, 1, 0) and i2c_go(I2C0, SENSOR_ADDR, n, I_READ)
    return i2c_go(I2C0, SENSOR_ADDR, n + 1, 0)


def camera_set_gap(ns):
    """Frame gap (end of one frame to the start of the next, ns) into registers 0x20-0x21, read back;
    True when the camera holds it."""
    mem32[I2C0 + DPORT + TXDATA] = SENSOR_GAP          # register pointer, then high byte first
    mem32[I2C0 + DPORT + TXDATA] = ns >> 8
    mem32[I2C0 + DPORT + TXDATA] = ns & 255
    ok = camera_reg(SENSOR_GAP, 2, 0)
    ok = ok and camera_reg(SENSOR_GAP, 2, I_READ)
    gap = ((rx_word(I2C0) & 255) << 8) | (rx_word(I2C0) & 255)
    puts("  Camera frame gap (end of one frame to the start of the next): ")
    dec(gap)
    say(" ns")
    return ok and gap == ns


def camera_size_set(w, h):
    """Frame size the detectors are set up for (cam_w, cam_h) until the camera's is read."""
    global cam_w, cam_h
    cam_w = w
    cam_h = h


def camera_frame_size():
    """Width and height of the camera's frames (registers 0x30-0x33, high byte first) into cam_w /
    cam_h; True when the transfer succeeded."""
    global cam_w, cam_h
    ok = camera_reg(SENSOR_SIZE, 4, I_READ)
    cam_w = ((rx_word(I2C0) & 255) << 8) | (rx_word(I2C0) & 255)
    cam_h = ((rx_word(I2C0) & 255) << 8) | (rx_word(I2C0) & 255)
    puts("  Camera frame size (control registers 0x30-0x33): ")
    dec(cam_w)
    puts(" x ")
    dec(cam_h)
    nl()
    return ok


def camera_detect():
    """Object classes to detect (camera register 0x50, bit c; 0 = pedestrian only) into det_mask,
    the symbol style of each class (registers 0x51-0x55, 0-9; larger: 0) into det_style and the
    most targets tracked at any time (0x58, 1-32; 0 = 32) into max_targets; prints the selection."""
    global det_mask, det_style, max_targets
    ok = camera_reg(SENSOR_DETECT, 6, I_READ)
    det_mask = rx_word(I2C0) & 31
    if det_mask == 0:
        det_mask = 1
    det_style = 0
    c = 0
    while c < NDET:
        s = rx_word(I2C0) & 255
        if s > 9:
            s = 0
        det_style = det_style | (s << (c << 2))
        c += 1
    max_targets = camera_byte(SENSOR_MAXT)
    if max_targets == 0 or max_targets > NOBJ_MAX:
        max_targets = NOBJ_MAX
    puts("  Detection (camera registers 0x50-0x55, 0x58): up to ")
    dec(max_targets)
    say(" targets at a time; class, symbol colour, symbol style")
    c = 0
    while c < NDET:
        if det_mask & (1 << c):
            puts("    ")
            class_name(c)
            s = class_style(c)
            if c == C_AIR:
                puts(": green")
            elif c >= C_CAR:
                puts(": red")
            else:
                puts(": white")
            if s == 6:
                say(" solid box in the middle of the target")
            elif s == 7:
                say(" dashed box, solid corners")
            elif s == 8:
                say(" dashed box, solid corners, ticks to the centre")
            elif s == 9:
                say(" dashed triangle, solid vertices")
            else:
                if s & 1:
                    puts(" solid")
                else:
                    puts(" dashed")
                if s < 2:
                    say(" box")
                elif s < 4:
                    say(" circle")
                else:
                    say(" oval")
        c += 1
    return ok


def camera_byte(reg):
    """One camera control register (0 when the transfer fails)."""
    if camera_reg(reg, 1, I_READ):
        return rx_word(I2C0) & 255
    return 0


def camera_name(j):
    """The image name (camera registers 0x40-0x4F, ASCII, 0 ends it) into overlay text j's
    characters; returns its length (0-16)."""
    n = 0
    end = 0
    if camera_reg(SENSOR_NAME, 16, I_READ):
        q = 0
        while q < 4:
            w = 0
            k = 0
            while k < 4:
                c = rx_word(I2C0) & 255
                if c == 0:
                    end = 1
                if not end:
                    w = w | (c << (k << 3))
                    n += 1
                k += 1
            text_word(j, q, w)
            q += 1
    return n


def camera_stream_on():
    mem32[I2C0 + DPORT + TXDATA] = SENSOR_STREAM
    mem32[I2C0 + DPORT + TXDATA] = 1
    return i2c_go(I2C0, SENSOR_ADDR, 2, 0)


def set_format():
    """Program the ISP for the camera image format on GPIO0[30]; GPIO0[2] shows the result."""
    global fmt_cnt
    if mem32[GPIO0 + G_IN] & MONO_SEL:
        wreg(VP + VP_BYPASS, BYPASS_ALL, strings(
            "video_pipeline BYPASS",
            "0xFF: every ISP stage bypassed (monochrome camera): the raw",
            "value goes to R, G and B; applied at the next frame start"))
        wreg(GPIO0 + G_SET, LED_MONO, strings(
            "gpio0 SET",
            "write only (reads 0): the 1 in [2] sets OUT[2], lighting the",
            "monochrome LED; the other output pins are unchanged"))
    else:
        wreg(VP + VP_BYPASS, BYPASS_COLOUR, strings(
            "video_pipeline BYPASS",
            "0xF7: only [3] demosaic active (colour RGGB camera), the other",
            "ISP stages bypassed; applied at the next frame start"))
        wreg(GPIO0 + G_CLEAR, LED_MONO, strings(
            "gpio0 CLEAR",
            "write only (reads 0): the 1 in [2] clears OUT[2], turning the",
            "monochrome LED off; the other output pins are unchanged"))
    fmt_cnt += 1
