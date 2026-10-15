#!/usr/bin/env python3
# ***************
# Filename: make_street_gif.py
# Author: FPGA Cores 4 U
# Description: Writes the multi-class detection test's input: a colour
#   animated GIF of a street, 160 x 120 pixels (4:3), 30 frames of 100 ms
#   = 3 seconds, looping, with one object of every class video_processor
#   detects:
#     pedestrian  a walker in a dark coat and trousers with dark hair on the
#                 near pavement (right to left);
#     face        the walker's face (skin tone), large enough to be found;
#     automobile  a blue car in the near lane (left to right), with a
#                 driver whose head and face show in its front window (a
#                 person inside a vehicle: a second face, inside the car's
#                 box);
#     vehicle     a long green bus in the far lane (right to left).
#   The colours are chosen the way the detectors see them (object_tracker
#   colour mode): the coat is the only dark object (luma < 80); the car's
#   and bus's paint are the only saturated colours (|Cb - 128| + |Cr - 128|
#   >= 56) and they blend with the grey road into blue or green tints, never
#   into skin tone; facades, road and pavement are near-neutral greys, the
#   sky a light blue. The scene is rendered with 2 x 2 supersampling and a
#   little sensor noise, then reduced to one 256-colour palette (median
#   cut). Pure Python, no packages needed (the GIF writer of
#   make_pedestrian_gif.py, here with a colour palette).
#   The true box of every object in every frame is written next to the GIF
#   (<name>.truth.txt: frame class x0 y0 x1 y1; class 0 pedestrian, 1 face,
#   2 automobile, 3 vehicle; pixels at least half covered; a class with two
#   objects, the faces, has two lines per frame), which the testbench reads
#   to judge the tracking of each class.
# Date: 2026-10-14
# ***************
# Usage: make_street_gif.py [-o tb/images/street_scene.gif]
import argparse
import random

from make_pedestrian_gif import lzw_encode

W, H = 160, 120                        # 4:3
FRAMES, DELAY_CS = 30, 10              # 30 x 100 ms = 3 s
SS = 2                                 # supersampling per axis
NOISE = 1.5                            # sensor noise, standard deviation per channel

SKY_TOP, SKY_LOW = (196, 212, 234), (222, 230, 240)
FACADES = [(-2, 38, 6, (176, 177, 181)), (38, 80, 0, (158, 161, 168)), (80, 122, 9, (184, 184, 186)),
           (122, 162, 3, (166, 168, 173))]           # x0, x1, roof y, tone (cool greys)
WINDOW = (122, 130, 142)
ROAD, LINE, KERB = (118, 119, 122), (226, 226, 222), (150, 150, 152)
PAVE = (176, 175, 172)
BUS, GLASS, TYRE = (20, 170, 50), (150, 166, 178), (96, 96, 98)
CAR, CAR_GLASS = (30, 60, 200), (172, 186, 198)
COAT, TROUSERS, HAIR, SKIN = (44, 46, 56), (34, 35, 40), (72, 56, 46), (226, 176, 146)


def background(x, y):
    """Static street colour at (x, y) (sub-pixel coordinates)."""
    if y < 58:
        for x0, x1, roof, tone in FACADES:
            if x0 <= x < x1 and y >= roof:
                wx, wy = (x - x0) % 9, (y - roof) % 10
                if 3 <= wx < 7 and 3 <= wy < 8 and y < 50:
                    return WINDOW
                return tone
        t = y / 58.0
        return tuple(int(a + (b - a) * t) for a, b in zip(SKY_TOP, SKY_LOW))
    if y < 61:
        return PAVE
    if y < 62:
        return KERB
    if y < 104:
        if 81 <= y < 83 and int(x) % 16 < 9:
            return LINE
        return ROAD
    if y < 105:
        return KERB
    return PAVE


def bus(x, y, bx):
    """Green bus, 72 long, far lane, left end at bx: (colour, class) or None."""
    if not (bx <= x < bx + 72 and 50 <= y < 80):
        return None
    if y >= 75:                                        # wheels below the body (whole body lines)
        for wc in (bx + 12, bx + 58):
            if (x - wc) ** 2 + (y - 75) ** 2 < 25:
                return (TYRE, None)
        return None
    if 54 <= y < 64 and bx + 4 <= x < bx + 68 and (x - bx - 4) % 12 < 9:
        return (GLASS, None)
    return (BUS, 3)


def driver(x, y, cx):
    """The car's driver: head in the front window (car left end at cx): (colour, class, object)."""
    if (x - cx - 24) ** 2 / 12.25 + (y - 84) ** 2 / 20.25 < 1.0:     # head 7 x 9
        if y < 81:
            return (HAIR, None, None)
        return (SKIN, 1, 1)
    return None


def car(x, y, cx):
    """Blue car, 38 long, near lane, left end at cx; a tall cabin with the driver in its front window."""
    if not (cx <= x < cx + 38 and 75 <= y < 104):
        return None
    if y >= 98:
        for wc in (cx + 8, cx + 30):
            if (x - wc) ** 2 + (y - 98) ** 2 < 16:
                return (TYRE, None)
        return None if y >= 100 else (CAR, 2)
    if y < 88:                                         # cabin
        if not (cx + 8 <= x < cx + 30):
            return None
        if y >= 77 and cx + 10 <= x < cx + 28 and not (cx + 18 <= x < cx + 20):
            return driver(x, y, cx) or (CAR_GLASS, None)
        return (CAR, 2)
    return (CAR, 2)


def walker(x, y, px, n):
    """Pedestrian centred on px, feet at 117: (colour, class); class 1 for the face."""
    swing = ((n % 8) - 4) / 4.0                        # leg / arm swing, -1 .. 1
    if (x - px) ** 2 / 25.0 + (y - 70) ** 2 / 36.0 < 1.0:          # head 10 x 12
        if y < 66 or abs(x - px - 1) > 4.2:            # hair on top and at the back
            return (HAIR, 0)
        return (SKIN, 1, 0)
    if 76 <= y < 98 and abs(x - px) < 7 - (y - 76) * 0.05:          # coat
        return (COAT, 0)
    if 95 <= y < 117:                                  # legs
        t = (y - 95) / 22.0
        for side in (-1, 1):
            lx = px + side * 2.5 + side * swing * 5 * t
            if abs(x - lx) < 2.2:
                return (TROUSERS, 0)
    if 78 <= y < 96:                                   # arms
        t = (y - 78) / 18.0
        for side in (-1, 1):
            ax = px + side * 6.5 - side * swing * 4 * t
            if abs(x - ax) < 1.8:
                return (COAT, 0)
    return None


def render(n, rng):
    """Frame n: rgb pixels and the coverage of every class."""
    bx = 60 - n * 1.7                                  # bus right to left
    cx = 4 + n * 2.0                                   # car left to right
    px = 142 - n * 0.8                                 # walker right to left
    img = []
    cover = {}                                         # (class, object) -> coverage per pixel
    for py in range(H):
        for pxl in range(W):
            acc = [0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    x, y = pxl + (sx + 0.5) / SS, py + (sy + 0.5) / SS
                    hit = walker(x, y, px, n) or car(x, y, cx) or bus(x, y, bx)
                    if hit:
                        col, cls = hit[0], hit[1]
                        obj = hit[2] if len(hit) > 2 else 0
                        if cls is not None:
                            cover.setdefault((cls, obj), [0] * (W * H))[py * W + pxl] += 1
                            if cls == 1 and obj == 0:     # the walker's face is part of the pedestrian
                                cover.setdefault((0, 0), [0] * (W * H))[py * W + pxl] += 1
                    else:
                        col = background(x, y)
                    for k in range(3):
                        acc[k] += col[k]
            img.append(tuple(max(0, min(255, int(round(a / (SS * SS) + rng.gauss(0, NOISE))))) for a in acc))
    boxes = []                                         # (class, x0, y0, x1, y1)
    for cls, obj in sorted(cover):
        cv = cover[(cls, obj)]
        xs = [i % W for i in range(W * H) if 2 * cv[i] >= SS * SS]
        ys = [i // W for i in range(W * H) if 2 * cv[i] >= SS * SS]
        if xs:
            boxes.append((cls, min(xs), min(ys), max(xs), max(ys)))
    return img, boxes


def median_cut(pixels, n):
    """Palette of n colours for the list of (r, g, b) pixels."""
    boxes = [pixels]
    while len(boxes) < n:
        boxes.sort(key=lambda b: max(max(p[k] for p in b) - min(p[k] for p in b) for k in range(3)) if len(b) > 1 else -1)
        b = boxes.pop()
        if len(b) < 2:
            boxes.append(b)
            break
        k = max(range(3), key=lambda k: max(p[k] for p in b) - min(p[k] for p in b))
        b.sort(key=lambda p: p[k])
        boxes += [b[:len(b) // 2], b[len(b) // 2:]]
    pal = [tuple(sum(p[k] for p in b) // len(b) for k in range(3)) for b in boxes]
    return pal + [(0, 0, 0)] * (n - len(pal))


def write_gif(path, frames, pal, comment):
    b = bytearray(b"GIF89a")
    b += W.to_bytes(2, "little") + H.to_bytes(2, "little") + bytes([0xF7, 0, 0])
    for c in pal:
        b += bytes(c)
    b += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"          # loop forever
    b += b"\x21\xFE" + bytes([len(comment)]) + comment + b"\x00"
    for f in frames:
        b += b"\x21\xF9\x04\x04" + DELAY_CS.to_bytes(2, "little") + b"\x00\x00"
        b += b"\x2C" + bytes(4) + W.to_bytes(2, "little") + H.to_bytes(2, "little") + b"\x00"
        b += b"\x08"
        data = lzw_encode(f)
        for i in range(0, len(data), 255):
            blk = data[i:i + 255]
            b += bytes([len(blk)]) + blk
        b += b"\x00"
    b += b"\x3B"
    with open(path, "wb") as fh:
        fh.write(b)
    return len(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", default="tb/images/street_scene.gif")
    out = ap.parse_args().o
    rng = random.Random(11)
    imgs, truth = [], []
    for n in range(FRAMES):
        img, boxes = render(n, rng)
        imgs.append(img)
        truth.append(boxes)
    sample = [p for img in imgs[::3] for p in img[::2]]
    pal = median_cut(sample, 256)
    cache = {}

    def index(p):
        if p not in cache:
            cache[p] = min(range(256), key=lambda i: sum((a - b) ** 2 for a, b in zip(p, pal[i])))
        return cache[p]

    frames = [[index(p) for p in img] for img in imgs]
    size = write_gif(out, frames, pal, b"street: pedestrian, face, blue car with its driver, green bus; 160x120, 3 s")
    with open(out.rsplit(".", 1)[0] + ".truth.txt", "w") as fh:
        fh.write("# frame class x0 y0 x1 y1 (true box; class 0 pedestrian, 1 face, 2 automobile, 3 vehicle)\n")
        for n, boxes in enumerate(truth):
            for bx in boxes:
                fh.write("%d %d %d %d %d %d\n" % ((n,) + bx))
    print(f"{out}: {W} x {H}, {FRAMES} frames x {DELAY_CS * 10} ms = {FRAMES * DELAY_CS / 100:.1f} s, {size} bytes")


if __name__ == "__main__":
    main()
