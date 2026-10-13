#!/usr/bin/env python3
# ***************
# Filename: make_pedestrian_gif.py
# Author: FPGA Cores 4 U
# Description: Writes the tracking test's input: a monochrome (256-level
#   grey) animated GIF that looks like black-and-white street video of a
#   pedestrian walking along a pavement, 128 x 96 pixels (4:3), 50 frames
#   of 100 ms = 5 seconds, looping.
#   The scene is rendered with 4 x 4 supersampling (anti-aliased edges) and
#   lit from the upper left: an overcast sky with soft clouds, stone and
#   brick facades with recessed windows, cornices and shop fronts, a tree,
#   a street lamp, pavement slabs in perspective with a kerb and a strip of
#   road. The pedestrian (dark coat and trousers, lighter face and hands,
#   an 8-frame walk cycle with bending knees and swinging arms, each limb
#   shaded) casts a soft shadow on the pavement. Camera effects: lens
#   vignetting, a gentle tone curve, film grain that changes every frame
#   and a few dust specks.
#   Every background tone stays above the tracking threshold (luma 80):
#   the pedestrian's dark clothing is the only dark object, as in a
#   photograph of someone in a dark coat on a bright street; the dust
#   specks are single pixels (the tracker's run filter ignores them).
#   Pure Python (own LZW encoder), no packages needed.
#   The true box of the figure in every frame is written next to the GIF
#   (<name>.truth.txt: frame x0 y0 x1 y1, pixels at least half covered)
#   for reference; the testbench measures its own truth from the frames.
# Date: 2026-10-11
# ***************
# Usage: make_pedestrian_gif.py [-o tb/images/pedestrian_walk.gif]
import argparse
import math
import random

W, H = 128, 96                         # 4:3
FRAMES, DELAY_CS = 50, 10              # 50 x 100 ms = 5 s
SS = 4                                 # supersampling per axis
GROUND = 83.0                          # y of the pedestrian's feet
HORIZON = 61.0                         # kerb line at the foot of the buildings
GRAIN = 3.0                            # film grain, standard deviation (grey levels)


# ---------------------------------------------------------------- GIF writer

def lzw_encode(idx, min_bits=8):
    """GIF LZW of a list of colour indices -> bytes (code stream, before sub-blocking)."""
    clear, eoi = 1 << min_bits, (1 << min_bits) + 1
    out, acc, nacc = bytearray(), 0, 0
    width = min_bits + 1

    def emit(code):
        nonlocal acc, nacc
        acc |= code << nacc
        nacc += width
        while nacc >= 8:
            out.append(acc & 255)
            acc >>= 8
            nacc -= 8

    table = {(i,): i for i in range(clear)}
    nxt = eoi + 1
    emit(clear)
    cur = (idx[0],)
    for k in idx[1:]:
        s = cur + (k,)
        if s in table:
            cur = s
            continue
        emit(table[cur])
        if nxt < 4096:
            table[s] = nxt
            nxt += 1
            if nxt - 1 == (1 << width) and width < 12:
                width += 1
        else:                          # table full: start again
            emit(clear)
            table = {(i,): i for i in range(clear)}
            nxt = eoi + 1
            width = min_bits + 1
        cur = (k,)
    emit(table[cur])
    emit(eoi)
    if nacc:
        out.append(acc & 255)
    return bytes(out)


def write_gif(path, frames, delay_cs):
    """frames: lists of W*H grey levels 0-255; global palette of 256 greys, loops forever."""
    b = bytearray(b"GIF89a")
    b += W.to_bytes(2, "little") + H.to_bytes(2, "little") + bytes([0xF7, 0, 0])
    for g in range(256):
        b += bytes([g, g, g])
    b += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"          # loop forever
    c = b"pedestrian walking, black and white street video, 128x96, 5 s"
    b += b"\x21\xFE" + bytes([len(c)]) + c + b"\x00"
    for f in frames:
        b += b"\x21\xF9\x04\x04" + delay_cs.to_bytes(2, "little") + b"\x00\x00"   # disposal 1: keep
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


# ---------------------------------------------------------------- textures

def hash01(ix, iy, seed):
    h = (ix * 374761393 + iy * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def vnoise(x, y, seed):
    """Smooth value noise, about -0.5 .. 0.5."""
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a = hash01(ix, iy, seed) + (hash01(ix + 1, iy, seed) - hash01(ix, iy, seed)) * fx
    b = hash01(ix, iy + 1, seed) + (hash01(ix + 1, iy + 1, seed) - hash01(ix, iy + 1, seed)) * fx
    return a + (b - a) * fy - 0.5


def fbm(x, y, seed, octaves=3):
    v, amp = 0.0, 1.0
    for o in range(octaves):
        v += amp * vnoise(x, y, seed + o)
        x, y, amp = x * 2.03, y * 2.03, amp * 0.5
    return v


# ---------------------------------------------------------------- the street (static)

BUILDINGS = [  # x0, x1, roof y, facade tone, window pitch, kind
    (-2, 30, 14, 172, 7, "stone"),
    (30, 63, 6, 150, 8, "brick"),
    (63, 92, 19, 182, 7, "stone"),
    (92, 130, 10, 160, 9, "brick"),
]


def street(x, y):
    """Grey level (0..255, before the camera) of the street at sub-pixel (x, y)."""
    if y >= HORIZON:                                    # kerb, pavement and road
        if y < HORIZON + 2.2:
            return 150 + 18 * (y - HORIZON) / 2.2       # kerb face, lit from above
        if y > 90.5:                                    # road at the bottom edge, asphalt
            return 128 + 10 * fbm(x * 0.6, y * 0.6, 11)
        depth = y - HORIZON + 6.0
        v = 176 + 6 * (y - HORIZON) / 30 + 7 * fbm(x * 0.35, y * 0.5, 3)
        u = (x - 64) * 22.0 / depth                     # slab joints converging in perspective
        if abs(u - round(u / 9.0) * 9.0) < 0.3 * 22.0 / depth:
            v -= 22
        row = 120.0 / depth
        if abs(row - round(row)) < 0.06:
            v -= 18
        return v
    for x0, x1, roof, tone, pitch, kind in BUILDINGS:
        if x0 <= x < x1 and y >= roof:
            v = tone + 6 * fbm(x * 0.5, y * 0.5, 5)
            if kind == "brick":                         # courses of brick
                course = int(y / 1.5)
                if (y / 1.5) % 1.0 < 0.18:
                    v -= 9
                elif ((x + (course % 2) * 1.5) / 3.0) % 1.0 < 0.12:
                    v -= 6
            if y < roof + 2.0:                          # cornice: lit top, shadow under it
                v += 14 if y < roof + 1.0 else -16
            elif x < x0 + 1.0:                          # side lit from the left
                v += 10
            elif x > x1 - 1.0:
                v -= 12
            # windows: recessed panes, a shadowed reveal, a bright reflection, a lit sill
            fx = (x - x0 - 3.0) % pitch
            fy = (y - roof - 6.0) % 10.0
            upper = roof + 4 < y < HORIZON - 9 and x0 + 2 < x < x1 - 3 and fx < pitch - 3.5
            if upper and fy < 6.0:
                v = 124 + 16 * vnoise(x * 0.4, y * 0.4, 9)      # glass reflecting the sky
                if fx < 0.8 or fy < 0.8:
                    v -= 8
                if fx > pitch - 4.5 and fy < 2.5:
                    v += 30
            elif upper and fy < 6.9:
                v += 22
            if kind == "stone" and y > HORIZON - 9:     # shop front: canopy and display window
                if y < HORIZON - 7.5:
                    v = 112
                elif x0 + 4 < x < x1 - 4 and y < HORIZON - 1:
                    v = 118 + 14 * vnoise(x * 0.3, y * 0.6, 21)
            return v
    return 228 - 0.35 * y + 14 * fbm(x * 0.06, y * 0.12, 7, 4)   # sky with soft clouds


def tree(x, y):
    """Tree in front of the buildings at x ~ 104: grey level or None."""
    if 102.6 <= x <= 105.0 + (y - 40) * 0.03 and 40 <= y <= HORIZON + 1:
        return 114 + 10 * (x < 103.4) + 5 * fbm(x, y * 0.5, 13)
    d = ((x - 104) / 13.0) ** 2 + ((y - 30) / 12.0) ** 2
    n = fbm(x * 0.25, y * 0.25, 17, 4)
    if d + 0.6 * n < 0.85:
        lit = 0.55 - 0.45 * ((x - 96) / 20 + (y - 22) / 20)  # brighter towards the light
        return 118 + 30 * max(0.0, min(1.0, lit)) + 20 * n
    return None


def lamp(x, y):
    """Street lamp at x ~ 44 (painted iron, mid grey)."""
    if 43.4 <= x <= 44.8 and 24 <= y <= HORIZON + 1.5:
        return 112 + 20 * (x < 44.0)
    if 40.5 <= x <= 47.8 and 21.0 <= y <= 24.0:
        return 110 + 26 * (y < 22.0)
    return None


def background():
    img = [0.0] * (W * H)
    for py in range(H):
        for px in range(W):
            acc = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    x, y = px + (sx + 0.5) / SS, py + (sy + 0.5) / SS
                    v = street(x, y)
                    t = tree(x, y)
                    if t is not None:
                        v = t
                    lv = lamp(x, y)
                    if lv is not None:
                        v = lv
                    acc += v
            img[py * W + px] = acc / (SS * SS)
    return img


# ---------------------------------------------------------------- the pedestrian

def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy or 1)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy), t


def figure(cx, phase):
    """Body parts of the walker (feet on GROUND, centre column cx, phase 0..1 of the walk cycle),
    back to front: ((a, b), radius at a, radius at b, lit tone, shaded tone)."""
    s = math.sin(2 * math.pi * phase)
    bob = 0.8 * abs(math.cos(2 * math.pi * phase))
    hip = (cx, GROUND - 16.5 + bob)
    neck = (cx + 0.8, GROUND - 29.5 + bob)
    head = (cx + 1.3, GROUND - 33.0 + bob)
    far, near = [], []
    for side in (-1, 1):                                # far limbs darker, behind the body
        dim = 0.75 if side < 0 else 1.0
        a = side * 0.48 * s                             # thigh swing
        knee = (hip[0] + 8.2 * math.sin(a), hip[1] + 8.2 * math.cos(a))
        bend = 0.55 * max(0.0, -side * s) + 0.08
        ankle = (knee[0] + 7.8 * math.sin(a - bend), knee[1] + 7.8 * math.cos(a - bend))
        toe = (ankle[0] + 2.6, ankle[1] + 0.4)
        arm = -side * 0.55 * s                          # arms swing against the legs
        shoulder = (neck[0] - 0.2, neck[1] + 1.6)
        elbow = (shoulder[0] + 6.0 * math.sin(arm), shoulder[1] + 6.0 * math.cos(arm))
        wrist = (elbow[0] + 5.6 * math.sin(arm + 0.35), elbow[1] + 5.6 * math.cos(arm + 0.35))
        hand = (wrist[0] + 0.9 * math.sin(arm + 0.4), wrist[1] + 0.9 * math.cos(arm + 0.4))
        parts = [((hip, knee), 2.0, 1.6, 34 * dim, 24 * dim),          # trousers
                 ((knee, ankle), 1.6, 1.2, 32 * dim, 22 * dim),
                 ((ankle, toe), 1.0, 0.8, 22 * dim, 16 * dim),         # shoe
                 ((shoulder, elbow), 1.5, 1.3, 46 * dim, 30 * dim),    # sleeve
                 ((elbow, wrist), 1.3, 1.1, 44 * dim, 28 * dim),
                 ((wrist, hand), 0.9, 0.9, 150 * dim, 112 * dim)]      # hand
        (far if side < 0 else near).append(parts)
    body = [((neck, hip), 3.1, 3.4, 48, 30),                           # coat
            ((hip, (hip[0] + 0.3, hip[1] + 3.0)), 3.4, 3.6, 44, 28),   # coat hem
            ((neck, (neck[0] + 0.4, neck[1] - 1.2)), 1.1, 1.1, 120, 90),  # neck
            ((head, head), 2.9, 2.9, 150, 104),                        # face
            (((head[0] - 1.3, head[1] - 1.0), (head[0] - 1.6, head[1] + 0.2)), 2.3, 2.1, 38, 26)]  # hair
    return far[0] + body[:2] + near[0][:3] + body[2:] + near[0][3:]


def body_tone(parts, x, y):
    """Grey of the front-most part covering (x, y), shaded with light from the left, or None."""
    tone = None
    for (a, b), ra, rb, lit, dark in parts:
        d, t = seg_dist(x, y, a[0], a[1], b[0], b[1])
        r = ra + (rb - ra) * t
        if d <= r:
            nx = (x - (a[0] + t * (b[0] - a[0]))) / max(r, 0.5)
            tone = dark + (lit - dark) * max(0.0, min(1.0, 0.5 - 0.6 * nx))
    return tone


def in_shadow(parts, x, y):
    """The walker's shadow on the pavement: the figure laid down towards the lower right."""
    if y < GROUND - 1.5:
        return False
    for (a, b), ra, rb, _, _ in parts:
        ax, ay = a[0] + (GROUND - a[1]) * 0.9, GROUND - (GROUND - a[1]) * 0.12
        bx, by = b[0] + (GROUND - b[1]) * 0.9, GROUND - (GROUND - b[1]) * 0.12
        d, t = seg_dist(x, y, ax, ay, bx, by)
        if d <= (ra + (rb - ra) * t) * 0.55 + 0.4:
            return True
    return False


def render_figure(img, cx, phase):
    """Composites the walker and its shadow over img; returns the figure's box (pixels at least
    half covered)."""
    parts = figure(cx, phase)
    x0, y0, x1, y1 = W, H, -1, -1
    n = SS * SS
    for py in range(max(0, int(GROUND - 38)), min(H, int(GROUND + 5))):
        for px in range(max(0, int(cx - 12)), min(W, int(cx + 32))):
            fsum, cov, shade = 0.0, 0, 0
            for sy in range(SS):
                for sx in range(SS):
                    x, y = px + (sx + 0.5) / SS, py + (sy + 0.5) / SS
                    tone = body_tone(parts, x, y)
                    if tone is not None:
                        fsum += tone
                        cov += 1
                    elif in_shadow(parts, x, y):
                        shade += 1
            if cov == 0 and shade == 0:
                continue
            bgv = img[py * W + px]
            img[py * W + px] = (fsum + bgv * (n - cov - shade) + bgv * 0.66 * shade) / n
            if 2 * cov >= n:
                x0, y0, x1, y1 = min(x0, px), min(y0, py), max(x1, px), max(y1, py)
    return x0, y0, x1, y1


# ---------------------------------------------------------------- camera

def camera(img, rng):
    """Vignetting, a soft tone curve (brighter highlights), film grain and dust -> 8 bits."""
    out = [0] * (W * H)
    for py in range(H):
        for px in range(W):
            r2 = ((px - W / 2) / (W / 2)) ** 2 + ((py - H / 2) / (H / 2)) ** 2
            t = img[py * W + px] * (1.0 - 0.10 * r2) / 255.0
            if t > 0.5:                                 # brighter highlights
                t += 0.06 * math.sin(math.pi * (t - 0.5) * 2)
            v = 255.0 * t + rng.gauss(0.0, GRAIN)
            out[py * W + px] = max(0, min(255, int(round(v))))
    for _ in range(4):                                  # dust specks on the film
        out[rng.randrange(H) * W + rng.randrange(W)] = 30 + rng.randrange(20)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", default="tb/images/pedestrian_walk.gif")
    out = ap.parse_args().o
    rng = random.Random(7)
    bg = background()
    frames, truth = [], []
    for n in range(FRAMES):
        img = list(bg)
        cx = 12 + n * 98 / (FRAMES - 1)                 # left to right in 5 s
        truth.append((n,) + render_figure(img, cx, n / 8.0))
        frames.append(camera(img, rng))
    size = write_gif(out, frames, DELAY_CS)
    with open(out.rsplit(".", 1)[0] + ".truth.txt", "w") as fh:
        fh.write("# frame x0 y0 x1 y1 (true box of the pedestrian)\n")
        for t in truth:
            fh.write("%d %d %d %d %d\n" % t)
    print(f"{out}: {W} x {H}, {FRAMES} frames x {DELAY_CS * 10} ms = {FRAMES * DELAY_CS / 100:.1f} s, {size} bytes")


if __name__ == "__main__":
    main()
