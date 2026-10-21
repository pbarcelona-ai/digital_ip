"""Model compiler for the NPU (ip/ai/npu/model/npu_model.py): an Ultralytics YOLOv8 detector -> an INT8 DDR image.

Steps:
  1. lower: the fused model (Conv + BatchNorm) walked into NPU operations: CONV (with SiLU), MAXPOOL, ADD,
     UPSAMPLE, concatenation (no operation: placement), per detection scale DECODE (to a candidate buffer)
     and NMS (foreground first) at the end; C2f's split is a view of its first convolution's output;
  2. calibrate: a floating-point run of that operation list on sample frames records the range of every
     tensor (and of every convolution before its activation); the run's raw outputs are checked against
     the Ultralytics model's;
  3. place: tensors are given DDR storage; the members of a concatenation share one storage (each written
     at its channel offset), so a concatenation costs nothing; all tensors of one storage share one scale;
  4. quantise: weights INT8 per output channel, activations INT8 per scale group (symmetric), bias INT32,
     requantisation multiplier / shift per output channel, the activation LUT (SiLU) per convolution, the
     decode LUTs (exp for the box distributions, sigmoid for the class score);
  5. emit: weights, LUTs and 64-byte descriptors in one image, loaded at its base address in DDR.

The frame-dependent letterbox (INPUT) and the mapping of boxes back to frame pixels (DECODE) come from NPU
registers at run time (the firmware sets them per sequence), so the image does not depend on the frame size.
A large input (longer side over 960) also gets a second pass of the network at about 640 (shape2_for, the
second letterbox LB2_*): a detector trained at 640 splits an object that fills much of a 1920-wide frame
into part boxes; the low-resolution pass sees it whole, and the one NMS keeps the whole box.
Usage (library): prog = compile_model(weights, n=320, calib=[rgb frames]); prog.image, prog.base, prog.desc,
prog.tensor_bytes; program() / calibrate() read sample frames with the calling design's sim.Input (its
system simulation, e.g. image_processing/video_processor/pysim, on sys.path). CLI: npu_compiler.py
--weights W --pysim DIR [--n 320] [inputs ...] compiles and compares the INT8 detections with the
Ultralytics model's on the given inputs (default: the real-life inputs of DIR's design).
"""
import math
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
IP_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))                 # ip/
sys.path.insert(0, os.path.join(IP_ROOT, "shared", "pymodel"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "model"))

import npu_model as npu                       # noqa: E402

PAD = 114                         # letterbox grey (Ultralytics)


# ======================================================================= IR

class T:
    """A tensor: storage s (index), channel offset c0, channels c, size h x w."""

    def __init__(self, s, c0, c, h, w):
        self.s, self.c0, self.c, self.h, self.w = s, c0, c, h, w


class Graph:
    def __init__(self):
        self.ops = []                 # (kind, dict)
        self.storages = []            # [channels, h, w]

    def new(self, c, h, w):
        self.storages.append([c, h, w])
        return T(len(self.storages) - 1, 0, c, h, w)


def silu(x):
    return x / (1.0 + np.exp(-x))


def lower(model, nw, nh):
    """The YOLOv8 DetectionModel (fused) as NPU operations for an nw x nh input (multiples of 32)."""
    import torch.nn as nn
    g = Graph()
    x = g.new(3, nh, nw)
    g.ops.append(("input", dict(out=x)))
    outs = []

    def conv(m, x, act=True):
        cv = m.conv if hasattr(m, "conv") else m
        k, s, p = cv.kernel_size[0], cv.stride[0], cv.padding[0]
        ho, wo = (x.h + 2 * p - k) // s + 1, (x.w + 2 * p - k) // s + 1
        y = g.new(cv.out_channels, ho, wo)
        w = cv.weight.detach().numpy().astype(np.float64)
        b = cv.bias.detach().numpy().astype(np.float64) if cv.bias is not None else np.zeros(cv.out_channels)
        act = act and isinstance(getattr(m, "act", None), nn.SiLU)
        g.ops.append(("conv", dict(x=x, y=y, w=w, b=b, k=k, s=s, p=p, act=act)))
        return y

    def view(t, c0, c):
        return T(t.s, t.c0 + c0, c, t.h, t.w)

    def concat(ts):
        c = sum(t.c for t in ts)
        y = g.new(c, ts[0].h, ts[0].w)
        g.ops.append(("concat", dict(xs=ts, y=y)))
        return y

    def add(a, b):
        y = g.new(a.c, a.h, a.w)
        g.ops.append(("add", dict(a=a, b=b, y=y)))
        return y

    for i, m in enumerate(model.model):
        name = type(m).__name__
        src = [outs[j] if j >= 0 else (outs[-1] if outs else x) for j in ([m.f] if isinstance(m.f, int) else m.f)]
        if isinstance(m.f, int) and m.f == -1:
            src = [outs[-1] if outs else x]
        if name == "Conv":
            y = conv(m, src[0])
        elif name == "C2f":
            t = conv(m.cv1, src[0])
            half = t.c // 2
            ys = [view(t, 0, half), view(t, half, half)]
            for b in m.m:
                z = conv(b.cv2, conv(b.cv1, ys[-1]))
                ys.append(add(ys[-1], z) if b.add else z)
            y = conv(m.cv2, concat(ys))
        elif name == "SPPF":
            t = conv(m.cv1, src[0])
            ys = [t]
            k = m.m.kernel_size
            for _ in range(3):
                z = g.new(t.c, t.h, t.w)
                g.ops.append(("maxpool", dict(x=ys[-1], y=z, k=k, s=1, p=k // 2)))
                ys.append(z)
            y = conv(m.cv2, concat(ys))
        elif name == "Upsample":
            t = src[0]
            y = g.new(t.c, 2 * t.h, 2 * t.w)
            g.ops.append(("upsample", dict(x=t, y=y)))
        elif name == "Concat":
            y = concat(src)
        elif name == "Detect":
            for lvl, t in enumerate(src):
                bx = conv(m.cv2[lvl][2], conv(m.cv2[lvl][1], conv(m.cv2[lvl][0], t)), act=False)
                cl = conv(m.cv3[lvl][2], conv(m.cv3[lvl][1], conv(m.cv3[lvl][0], t)), act=False)
                g.ops.append(("decode", dict(box=bx, cls=cl, stride=int(m.stride[lvl]), level=lvl,
                                             reg=m.reg_max, nc=m.nc)))
            y = None
        else:
            raise SystemExit(f"npu_compiler: layer {i} {name} is not supported")
        outs.append(y)
    return g


# ======================================================================= float run (calibration, check)

def letterbox(rgb, nw, nh):
    """The NPU's INPUT operation before its 7-bit step: bilinear scaling (npu.bilinear), centred, grey
    padding."""
    fh, fw = rgb.shape[:2]
    sw, sh, step, ox, oy, _ = geometry(fw, fh, nw, nh)
    out = np.full((nh, nw, 3), PAD, np.uint8)
    out[oy:oy + sh, ox:ox + sw] = npu.bilinear(rgb, sw, sh, step)
    return out


def geometry(fw, fh, nw, nh):
    """Letterbox of a fw x fh frame in an nw x nh input: picture size, Q16 step, offset, Q16 frame px per
    input px. Integer arithmetic only (the firmware computes the same values for the NPU registers)."""
    if fw * nh >= fh * nw:
        sw, sh = nw, (2 * fh * nw + fw) // (2 * fw)
    else:
        sw, sh = (2 * fw * nh + fh) // (2 * fh), nh
    step = (fw << 16) // sw
    inv = ((fw << 16) + (sw >> 1)) // sw
    return sw, sh, step, (nw - sw) >> 1, (nh - sh) >> 1, inv


def shape_for(fw, fh):
    """The NPU input of a fw x fh frame at its native size: each side rounded up to a multiple of 32."""
    return ((fw + 31) // 32) * 32, ((fh + 31) // 32) * 32


TRAIN_SIDE = 640                  # the detector's training size: objects much larger than this are seen as parts


def shape2_for(nw, nh):
    """The second, low-resolution pass of an nw x nh input (longer side TRAIN_SIDE, rounded up to 32), for
    objects too large for the native pass; None when the input's longer side is at most 1.5 x TRAIN_SIDE."""
    m = max(nw, nh)
    if 2 * m <= 3 * TRAIN_SIDE:
        return None
    return shape_for((nw * TRAIN_SIDE + m // 2) // m, (nh * TRAIN_SIDE + m // 2) // m)


def run_float(g, img, ranges=None, pct=100.0):
    """Float values of every storage for one letterboxed image (h x w x 3 uint8); updates ranges (per
    tensor the largest |value|, or its pct percentile when pct < 100: rare outliers clip), keyed by
    operation / storage index, so ranges measured at one input size serve every size."""
    import torch
    import torch.nn.functional as F
    st = [None] * len(g.storages)

    def get(t):
        return st[t.s][t.c0:t.c0 + t.c]

    def put(t, v):
        if st[t.s] is None:
            st[t.s] = np.zeros(g.storages[t.s], np.float64)
        st[t.s][t.c0:t.c0 + t.c] = v

    def note(key, v):
        if ranges is not None:
            a = np.abs(v)
            m = float(a.max()) if pct >= 100.0 else float(np.percentile(a, pct))
            ranges[key] = max(ranges.get(key, 0.0), m)
    raw = []
    for oi, (kind, o) in enumerate(g.ops):
        if kind == "input":
            put(o["out"], img.transpose(2, 0, 1).astype(np.float64) / 255.0)
        elif kind == "conv":
            x = torch.from_numpy(get(o["x"])[None])
            y = F.conv2d(x, torch.from_numpy(o["w"]), torch.from_numpy(o["b"]), o["s"], o["p"])[0].numpy()
            note(("pre", oi), y)
            put(o["y"], silu(y) if o["act"] else y)
        elif kind == "maxpool":
            x = torch.from_numpy(get(o["x"])[None])
            put(o["y"], F.max_pool2d(x, o["k"], o["s"], o["p"])[0].numpy())
        elif kind == "upsample":
            put(o["y"], np.repeat(np.repeat(get(o["x"]), 2, 1), 2, 2))
        elif kind == "add":
            put(o["y"], get(o["a"]) + get(o["b"]))
        elif kind == "concat":
            c = 0
            for t in o["xs"]:
                put(T(o["y"].s, c, t.c, t.h, t.w), get(t))
                c += t.c
        elif kind == "decode":
            raw.append((get(o["box"]), get(o["cls"])))
    if ranges is not None:
        for i, v in enumerate(st):
            if v is not None:
                note(("st", i), v)
    return raw


# ======================================================================= placement and scales

def place(g):
    """Concatenation members share the concatenation's storage: root[s] = (root storage, channel offset)."""
    parent = list(range(len(g.storages)))
    off = [0] * len(g.storages)

    def root(s):
        o = 0
        while parent[s] != s:
            o += off[s]
            s = parent[s]
        return s, o
    for kind, o in g.ops:
        if kind != "concat":
            continue
        c = 0
        y = o["y"].s
        for t in o["xs"]:
            r, ro = root(t.s)
            if r == y:                                         # already inside (a view of an earlier member)
                c += t.c
                continue
            if t.c0 != 0 or g.storages[t.s][0] != t.c:
                # a view: the whole storage it belongs to must be placed so the view lands at offset c
                if parent[r] != r:
                    raise SystemExit("npu_compiler: a storage in two concatenations needs a copy")
                parent[r], off[r] = y, c - (ro + t.c0)
            else:
                if parent[r] != r:
                    raise SystemExit("npu_compiler: a storage in two concatenations needs a copy")
                parent[r], off[r] = y, c - ro
            c += t.c
    return root


def scale_groups(g, root):
    """Union of storages that must share a scale: one placement root, maxpool / upsample in and out."""
    grp = {}
    for s in range(len(g.storages)):
        grp[s] = root(s)[0]
    uf = {r: r for r in set(grp.values())}

    def find(a):
        while uf[a] != a:
            uf[a] = uf[uf[a]]
            a = uf[a]
        return a
    for kind, o in g.ops:
        if kind in ("maxpool", "upsample"):
            a, b = find(grp[o["x"].s]), find(grp[o["y"].s])
            uf[a] = b
    return {s: find(r) for s, r in grp.items()}


# ======================================================================= quantise and emit

def mult_shift(m):
    """M as (multiplier < 2^15, shift >= 1): M ~ multiplier / 2^shift."""
    if m <= 0:
        return 0, 1
    s = 14 - int(math.floor(math.log2(m)))
    s = max(1, s)
    q = int(round(m * (1 << s)))
    while q >= 1 << 15:
        s -= 1
        q = int(round(m * (1 << s)))
    if s < 1:
        raise SystemExit(f"npu_compiler: requantisation factor {m} too large for a 15-bit multiplier")
    return q, s


class Program:
    """The compiled image: bytes at base; descriptors from desc; tensor arena after the image."""

    def __init__(self):
        self.blob = bytearray()
        self.base = 0
        self.desc = 0
        self.arena = 0
        self.arena_bytes = 0
        self.ops = 0
        self.macs = 0
        self.n = 0
        self.nw = self.nh = 0
        self.nw2 = self.nh2 = 0                                 # second pass (0: none)
        self.input_addr = 0
        self.names = []

    def put(self, data, align=64):
        while len(self.blob) % align:
            self.blob.append(0)
        a = self.base + len(self.blob)
        self.blob += bytes(data)
        return a


def compile_model(weights, n=320, calib=(), conf=0.25, base=0x0100_0000, verbose=False, pct=100.0, ranges=None,
                  n2=None):
    """n: the input, n x n or (nw, nh); calib: frames measured for the ranges, unless ranges (from
    calibrate()) are given; n2: (nw, nh) of a second, low-resolution pass of the same network (FLAG_BANK2,
    the LB2_* letterbox) for large objects, or None. The two passes share the weights and LUTs, have their
    own tensors and fill one candidate buffer for the one NMS."""
    from ultralytics import YOLO
    nw, nh = (n, n) if isinstance(n, int) else n
    yolo = YOLO(weights)
    model = yolo.model.float().eval()
    model.fuse(verbose=False)
    passes = [(lower(model, nw, nh), nw, nh, 0)]
    if n2:
        passes.append((lower(model, n2[0], n2[1]), n2[0], n2[1], npu.FLAG_BANK2))
    if ranges is None:
        ranges = {}
        for rgb in calib:
            run_float(passes[0][0], letterbox(rgb, nw, nh), ranges, pct)

    prog = Program()
    prog.base, prog.n, prog.nw, prog.nh = base, nw, nw, nh
    prog.nw2, prog.nh2 = n2 if n2 else (0, 0)
    prog.names = yolo.names
    cand = prog.put(bytes(npu.CAND_MAX * npu.DET_WORDS * 4))   # decoded candidates of a frame (NMS input)
    const = {}                                                # op index -> constant addresses (shared by passes)
    descs, arenas = [], []
    for pi, (g, pw, ph, flag) in enumerate(passes):
        root = place(g)
        roots = sorted({root(s)[0] for s in range(len(g.storages))})
        arenas.append((roots, {r: g.storages[r][0] * g.storages[r][1] * g.storages[r][2] for r in roots}))
        descs += emit(prog, g, root, ranges, pw, ph, flag, pi, cand, const, conf)
        if pi == 0:
            input_root = root(g.ops[0][1]["out"].s)[0]
    nms = [0] * 16                                          # NMS: same class 0.45, other class 0.7, largest first
    nms[0], nms[1], nms[13], nms[14], nms[15] = npu.OP_NMS, cand, 450, 700, 800
    descs.append(nms)
    descs.append([npu.OP_END] + [0] * 15)
    # the descriptors after the constants, then the tensor arena (each pass's tensors in turn)
    while len(prog.blob) % 64:
        prog.blob.append(0)
    arena = prog.base + len(prog.blob) + len(descs) * npu.DESC_BYTES + 64
    taddr_of = {}
    a = arena
    for pi, (roots, size) in enumerate(arenas):
        for r in roots:
            taddr_of[(pi, r)] = a
            a += (size[r] + 63) & ~63
    prog.arena, prog.arena_bytes = arena, a - arena
    words = bytearray()
    for d in descs:
        for i, v in enumerate(d):
            if isinstance(v, tuple):
                d[i] = taddr_of[(v[1], v[2])] + v[3]
        words += struct.pack("<16I", *[v & 0xFFFFFFFF for v in d])
    prog.desc = prog.put(words)
    if prog.base + len(prog.blob) > arena:
        raise SystemExit("npu_compiler: the descriptors overlap the tensor arena")
    prog.ops = len(descs)
    prog.input_addr = taddr_of[(0, input_root)]
    prog.image = bytes(prog.blob)
    if verbose:
        print(f"npu_compiler: {prog.ops} descriptors, {len(prog.image)} image bytes, arena {prog.arena_bytes} "
              f"bytes, {prog.macs / 1e9:.2f} GMAC per frame", flush=True)
    return prog, passes[0][0], yolo


def emit(prog, g, root, ranges, nw, nh, flag, pi, cand, const, conf):
    """The descriptors of one pass (graph g at nw x nh): tensor addresses as ("T", pass, root storage,
    byte offset) for the arena; weights, LUTs and quantisation put once per operation index (const)."""
    groups = scale_groups(g, root)
    gmax = {}
    for s, gr in groups.items():
        gmax[gr] = max(gmax.get(gr, 1e-6), ranges.get(("st", s), 1e-6))
    in_group = groups[g.ops[0][1]["out"].s]
    scale = {gr: v / 127.0 for gr, v in gmax.items()}
    scale[in_group] = 2.0 / 255.0                               # INPUT: value = pixel >> 1
    sc = lambda t: scale[groups[t.s]]                           # noqa: E731
    descs = []

    def taddr(t):
        r, o = root(t.s)
        h, w = g.storages[r][1], g.storages[r][2]
        return ("T", pi, r, (o + t.c0) * h * w)

    for oi, (kind, o) in enumerate(g.ops):
        d = [0] * 16
        if kind == "input":
            t = o["out"]
            d[0] = npu.OP_INPUT | flag
            d[3] = taddr(t)
            d[7] = (nh << 16) | nw
            d[8] = (PAD >> 1) << 16
        elif kind == "conv":
            x, y = o["x"], o["y"]
            if oi not in const:
                w, b = o["w"], o["b"]
                sx, sy = sc(x), sc(y)
                sw = np.maximum(np.abs(w).reshape(w.shape[0], -1).max(1), 1e-12) / 127.0
                wq = np.clip(np.round(w / sw[:, None, None, None]), -127, 127).astype(np.int8)
                bq = np.round(b / (sw * sx)).astype(np.int64)
                if o["act"]:
                    spre = max(ranges.get(("pre", oi), 1e-6), 1e-6) / 127.0
                    lut = np.clip(np.round(silu(np.arange(-128, 128) * spre) / sy), -128, 127).astype(np.int8)
                    target = spre
                else:
                    lut = None
                    target = sy
                ms = [mult_shift(float(sw[c] * sx / target)) for c in range(w.shape[0])]
                qv = np.array(ms, np.int32).reshape(-1)
                const[oi] = (prog.put(wq.tobytes()),
                             prog.put(np.clip(bq, -2**31, 2**31 - 1).astype(np.int32).tobytes()),
                             prog.put(qv.tobytes()), prog.put(lut.tobytes()) if lut is not None else 0)
            d[0] = npu.OP_CONV
            d[1], d[3] = taddr(x), taddr(y)
            d[4], d[5] = x.c, (x.h << 16) | x.w
            d[6], d[7] = y.c, (y.h << 16) | y.w
            d[8] = o["k"] | (o["s"] << 8) | (o["p"] << 16)
            d[9], d[10], d[11], d[12] = const[oi]
            prog.macs += y.c * x.c * o["k"] ** 2 * y.h * y.w
        elif kind == "maxpool":
            x, y = o["x"], o["y"]
            d[0] = npu.OP_MAXPOOL
            d[1], d[3] = taddr(x), taddr(y)
            d[4], d[5] = x.c, (x.h << 16) | x.w
            d[8] = o["k"] | (o["s"] << 8) | (o["p"] << 16)
        elif kind == "upsample":
            x, y = o["x"], o["y"]
            d[0] = npu.OP_UPSAMPLE
            d[1], d[3] = taddr(x), taddr(y)
            d[4], d[5] = x.c, (x.h << 16) | x.w
        elif kind == "add":
            a, b, y = o["a"], o["b"], o["y"]
            ra, rb = sc(a) / sc(y), sc(b) / sc(y)
            s = 14 - int(math.floor(math.log2(max(ra, rb))))
            d[0] = npu.OP_ADD
            d[1], d[2], d[3] = taddr(a), taddr(b), taddr(y)
            d[4], d[5] = y.c, (y.h << 16) | y.w
            d[13], d[14], d[15] = int(round(ra * (1 << s))), int(round(rb * (1 << s))), s
        elif kind == "concat":
            continue
        elif kind == "decode":
            bx, cl = o["box"], o["cls"]
            sb, scl = sc(bx), sc(cl)
            if oi not in const:
                exp_lut = np.round(32767 * np.exp(-np.arange(256) * sb)).astype(np.uint16)
                sig = np.round(255 / (1 + np.exp(-np.arange(-128, 128) * scl))).astype(np.uint8)
                const[oi] = prog.put(exp_lut.tobytes() + sig.tobytes())
            th = int(math.ceil(math.log(conf / (1 - conf)) / scl))
            d[0] = npu.OP_DECODE | flag
            d[1], d[2], d[3] = taddr(bx), taddr(cl), cand
            d[4] = (o["reg"] << 16) | o["nc"]
            d[5] = (bx.h << 16) | bx.w
            d[8] = o["stride"] | (o["level"] << 8)
            d[12] = const[oi]
            d[13] = max(-128, min(127, th)) & 0xFF
        descs.append(d)
    return descs


# ======================================================================= program cache

HDR_ADDR = 0x1000                 # DDR header the firmware reads: magic, descriptor address, input width, classes,
HDR_MAGIC = 0x4E505538            # input height, second pass width, height (0: none) ("NPU8")


def save_program(prog, path):
    """The compiled image and what the firmware / testbench need of it (.npz)."""
    np.savez(path, image=np.frombuffer(prog.image, np.uint8), base=prog.base, desc=prog.desc, n=prog.nw,
             nw=prog.nw, nh=prog.nh, nc=len(prog.names), arena=prog.arena, arena_bytes=prog.arena_bytes,
             macs=prog.macs, conf=getattr(prog, "conf", 0.25), pct=getattr(prog, "pct", 100.0),
             nw2=getattr(prog, "nw2", 0), nh2=getattr(prog, "nh2", 0),
             names=np.array([prog.names[i] for i in range(len(prog.names))]))


def load_program(path):
    z = np.load(path)
    prog = Program()
    prog.image = z["image"].tobytes()
    prog.base, prog.desc, prog.n = int(z["base"]), int(z["desc"]), int(z["n"])
    prog.nw = int(z["nw"]) if "nw" in z else prog.n
    prog.nh = int(z["nh"]) if "nh" in z else prog.n
    prog.nw2 = int(z["nw2"]) if "nw2" in z else 0
    prog.nh2 = int(z["nh2"]) if "nh2" in z else 0
    prog.arena, prog.arena_bytes, prog.macs = int(z["arena"]), int(z["arena_bytes"]), int(z["macs"])
    prog.names = {i: str(v) for i, v in enumerate(z["names"])}
    return prog


def calibrate(weights, inputs, path, pct=99.99, n=960, fit=(960, 720)):
    """Activation ranges of every tensor (keyed by operation / storage index, valid for any input size),
    measured on frames of inputs letterboxed to n x n; cached in path while newer than the weights, this
    compiler and npu_model.py."""
    srcs = [weights, os.path.abspath(__file__), os.path.abspath(npu.__file__)]
    if os.path.exists(path) and all(os.path.getmtime(path) > os.path.getmtime(s) for s in srcs):
        z = np.load(path)
        if abs(float(z["pct"]) - pct) < 1e-9:
            return {(str(k), int(i)): float(v) for k, i, v in zip(z["kind"], z["idx"], z["val"])}
    import sim
    from ultralytics import YOLO
    model = YOLO(weights).model.float().eval()
    model.fuse(verbose=False)
    g = lower(model, n, n)
    ranges = {}
    for p in inputs:
        d = sim.Input(p, 10.0, 0.0, 30, 0, 30, False, fit)
        for k in range(0, len(d.frames), max(1, len(d.frames) // 3)):
            run_float(g, letterbox(d.frames[k], n, n), ranges, pct)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    keys = sorted(ranges)
    np.savez(path, kind=np.array([k[0] for k in keys]), idx=np.array([k[1] for k in keys]),
             val=np.array([ranges[k] for k in keys]), pct=pct)
    return ranges


def program(weights, inputs, cache, n=320, conf=0.1, fit=(960, 720), pct=99.99):
    """The compiled program for an n x n or (nw, nh) input, from activation ranges calibrated on frames of
    inputs (calibrate(): once, cached next to the program); reused from cache while the weights, this
    compiler and npu_model.py are older than it and it was compiled for the same input size, threshold and
    calibration percentile (99.99: 91 % of the float model's detections against 88 % with the maxima).
    A large input gets the second, low-resolution pass (shape2_for)."""
    nw, nh = (n, n) if isinstance(n, int) else n
    n2 = shape2_for(nw, nh)
    srcs = [weights, os.path.abspath(__file__), os.path.abspath(npu.__file__)]
    if os.path.exists(cache) and all(os.path.getmtime(cache) > os.path.getmtime(s) for s in srcs):
        z = np.load(cache)
        two = (int(z["nw2"]), int(z["nh2"])) if "nw2" in z else (0, 0)
        if ("nh" in z and int(z["nw"]) == nw and int(z["nh"]) == nh and abs(float(z["conf"]) - conf) < 1e-9
                and abs(float(z["pct"]) - pct) < 1e-9 and two == (n2 or (0, 0))):
            return load_program(cache)
    stem = os.path.splitext(os.path.basename(weights))[0]
    ranges = calibrate(weights, inputs, os.path.join(os.path.dirname(cache), f"npu_ranges_{stem}_{pct:g}.npz"), pct)
    prog, _, _ = compile_model(weights, (nw, nh), conf=conf, verbose=True, pct=pct, ranges=ranges, n2=n2)
    prog.conf, prog.pct = conf, pct
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    save_program(prog, cache)
    return load_program(cache)


def load_into(ddr, prog):
    """The image at its base and the header at HDR_ADDR (what a boot loader would do)."""
    ddr.write(prog.base, np.frombuffer(prog.image, np.uint8))
    for i, v in enumerate((HDR_MAGIC, prog.desc, prog.nw, len(prog.names), prog.nh, prog.nw2, prog.nh2)):
        ddr.set_word(HDR_ADDR + 4 * i, v)


# ======================================================================= check against Ultralytics

def npu_detect(prog, rgb, ddr_size=256 << 20, max_det=300):
    """Run the compiled image on one frame (the NPU model, letterbox registers set as the firmware would):
    returns (detections [(x0, y0, x1, y1, class, score 0-255)], NPU clocks)."""
    ddr = npu.Ddr(ddr_size)
    ddr.write(prog.base, np.frombuffer(prog.image, np.uint8))
    fh, fw = rgb.shape[:2]
    frame_addr, det_addr = 0x0010_0000, 0x0080_0000
    ddr.write(frame_addr, np.ascontiguousarray(rgb, np.uint8))
    sw, sh, step, ox, oy, inv = geometry(fw, fh, prog.nw, prog.nh)
    core = npu.Npu(ddr)
    core.geom = dict(frame=frame_addr, stride=fw * 3, fw=fw, fh=fh, step=step, ox=ox, oy=oy, sw=sw, sh=sh, inv=inv)
    if prog.nw2:
        sw, sh, step, ox, oy, inv = geometry(fw, fh, prog.nw2, prog.nh2)
        core.geom2 = dict(core.geom, step=step, ox=ox, oy=oy, sw=sw, sh=sh, inv=inv)
    clocks = core.run(prog.desc, det_addr, max_det)
    dets = []
    for i in range(core.ndet):
        w = [ddr.word(det_addr + 16 * i + 4 * k) for k in range(3)]
        dets.append((w[0] & 0xFFFF, w[1] & 0xFFFF, w[0] >> 16, w[1] >> 16, w[2] & 0xFF, (w[2] >> 8) & 0xFF))
    return dets, clocks


def nms(dets, iou=0.45):
    """Class-aware greedy NMS (the firmware's rule, in Python for the check)."""
    out = []
    for d in sorted(dets, key=lambda d: -d[5]):
        ok = True
        for e in out:
            if e[4] != d[4]:
                continue
            ix = max(0, min(d[2], e[2]) - max(d[0], e[0]))
            iy = max(0, min(d[3], e[3]) - max(d[1], e[1]))
            inter = ix * iy
            union = (d[2] - d[0]) * (d[3] - d[1]) + (e[2] - e[0]) * (e[3] - e[1]) - inter
            if union > 0 and inter * 100 > iou * 100 * union:
                ok = False
                break
        if ok:
            out.append(d)
    return out


def main():
    import argparse
    import time
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*")
    ap.add_argument("--weights", required=True, help="Ultralytics YOLOv8 weights (.pt)")
    ap.add_argument("--pysim", required=True, help="the design's system simulation folder (sim.Input, run_pysim)")
    ap.add_argument("--n", type=int, default=320)
    ap.add_argument("--frames", type=int, default=5, help="frames checked per input")
    ap.add_argument("--pct", type=float, default=100.0, help="calibration percentile of |value| (100: the largest)")
    a = ap.parse_args()
    sys.path.insert(0, os.path.abspath(a.pysim))
    import glob
    import run_pysim
    import sim
    ins = a.inputs or sorted(f for f in glob.glob(os.path.join(run_pysim.IMAGES, "*"))
                             if f.lower().endswith((".gif",) + run_pysim.VIDEO_EXT)
                             and not os.path.exists(os.path.splitext(f)[0] + ".truth.txt"))
    data = [sim.Input(p, 10.0, 0.0, 30, 0, 30, False) for p in ins]
    calib = [d.frames[k] for d in data for k in range(0, len(d.frames), max(1, len(d.frames) // 3))]
    t0 = time.time()
    prog, g, yolo = compile_model(a.weights, a.n, calib, verbose=True, pct=a.pct)
    print(f"compiled in {time.time() - t0:.1f} s ({len(calib)} calibration frames)")
    tot_ref = tot_hit = tot_npu = 0
    for d in data:
        for k in range(0, min(len(d.frames), a.frames * 5), 5):
            rgb = d.frames[k]
            ref = yolo.predict(np.ascontiguousarray(letterbox(rgb, a.n, a.n)[..., ::-1]), imgsz=a.n, conf=0.25,
                               verbose=False)[0]
            fh, fw = rgb.shape[:2]
            sw, sh, step, ox, oy, inv = geometry(fw, fh, a.n, a.n)
            rb = []
            for c, b in zip(ref.boxes.cls.int().tolist(), ref.boxes.xyxy.tolist()):
                rb.append((c, [(b[0] - ox) * inv / 65536, (b[1] - oy) * inv / 65536,
                               (b[2] - ox) * inv / 65536, (b[3] - oy) * inv / 65536]))
            dets, clocks = npu_detect(prog, rgb)
            dets = nms(dets)
            hit = 0
            for c, b in rb:
                for e in dets:
                    if e[4] != c:
                        continue
                    ix = max(0, min(b[2], e[2]) - max(b[0], e[0]))
                    iy = max(0, min(b[3], e[3]) - max(b[1], e[1]))
                    u = (b[2] - b[0]) * (b[3] - b[1]) + (e[2] - e[0]) * (e[3] - e[1]) - ix * iy
                    if u > 0 and ix * iy / u >= 0.5:
                        hit += 1
                        break
            tot_ref += len(rb)
            tot_hit += hit
            tot_npu += len(dets)
        print(f"  {d.name[:40]:40s} reference {tot_ref:4d} found {tot_hit:4d} npu {tot_npu:4d} "
              f"(clocks per frame {clocks})", flush=True)
    print(f"INT8 NPU found {tot_hit} of {tot_ref} reference detections ({100.0 * tot_hit / max(1, tot_ref):.1f} %), "
          f"{tot_npu} NPU detections after NMS")


if __name__ == "__main__":
    main()
