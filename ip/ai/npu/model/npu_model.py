"""NPU: INT8 neural-network accelerator model (Python baseline of a new IP, ip/ai/npu; its RTL is to come).

A command processor reads a list of 64-byte layer descriptors from DDR and runs each on a 64 x 64 INT8
multiply-accumulate array (4096 MACs per clock, INT32 accumulation) with a DMA engine to DDR. Tensors live
in DDR as INT8, channel planes (C x H x W, row-major), so concatenation along channels is a placement of
the producers next to each other (no copy). Everything is integer arithmetic, defined here bit-exactly:
this module is the golden model of the RTL.

Operations (descriptor word 0 [7:0]):
  0 END       stop, raise DONE
  1 CONV      k x k convolution (k 1 / 3), stride 1 / 2, zero padding: acc = sum(w * x) + bias (INT32);
              q = clamp((acc * M[c] + 2^(S[c]-1)) >> S[c], -128, 127); with a LUT, out = LUT[q + 128]
              (the activation, e.g. SiLU, folded with the next scale), else out = q
  2 MAXPOOL   k x k, stride, padding (padding never wins)
  3 ADD       out = clamp((a * MA + b * MB + 2^(S-1)) >> S)
  4 UPSAMPLE  nearest, x2
  5 COPY      bytes
  6 INPUT     RGB888 frame buffer -> 3 x NH x NW INT8 letterbox (word 7: NH << 16 | NW): bilinear scaling
              (bilinear(): 8-bit weights, centres aligned) by STEP (Q16, source pixels per output pixel), the
              picture at OFFSET, padding PAD (word 8 [23:16]); value = pixel >> 1;
              the frame address, stride, size and the letterbox come from the NPU registers (geom)
  7 DECODE    one detection scale: box tensor (4 x REG distribution logits) and class tensor (NC logits);
              for every anchor whose best class logit reaches THRESH: the class, its score (sigmoid LUT,
              0-255) and the box from the distributions (exp LUT, expectation) mapped back to frame
              pixels (letterbox offset and INV from the registers); appended to the candidate list at word 3
              (4 words each, up to CAND_MAX)
  8 NMS       the candidates: suppressed when a higher-score one of the same class overlaps it by more than
              word 13 (per mille, 450) or one of another class by more than word 14 (700: the same object
              seen as two classes), or a same-class one covers word 15 (800) of the smaller box (a part of
              the object, e.g. the front of a long car); the rest ordered by box area, largest first, and
              the first DET_MAX written to the detection list (DET_ADDR)

Descriptor flags (word 0 [15:8]): [0] BANK2: INPUT and DECODE use the second letterbox registers (LB2_*),
for a second, low-resolution pass of the network in the same program (large objects: a detector trained at
640 sees an object filling a 1920-wide frame as parts); both passes' DECODEs fill one candidate buffer and
one NMS takes them all.

Descriptor words (64 bytes, little-endian 32-bit):
  0 op | flags << 8    1 in      2 in2     3 out     4 c_in    5 h_in << 16 | w_in
  6 c_out              7 h_out << 16 | w_out          8 k | stride << 8 | pad << 16
  9 weights           10 bias   11 quant (M 32-bit, S 32-bit per output channel)   12 lut
  13 p0               14 p1     15 p2         (operation parameters, see each operation)
Timing: per operation max(compute cycles, DDR bytes / BUS_BYTES) + OP_OVERHEAD clocks (DDR modelled as a
flat byte array with a fixed bandwidth).

NpuTop is the IP with its register block (npu_regs.json): the frame writer (CTRL [0] enable, [2] frame
writer on: each frame written as RGB888 at FRAME_ADDR, FRAME_STRIDE bytes per line; [1] AUTO: a run after
every frame), CMD [0] starts a run on the frame buffer with the letterbox registers (LB_* and LB2_*);
IRQ_STATUS [0] done, [1] error (a bad descriptor or operation); STATUS [1] a frame written since the last
run, DET_COUNT, CYCLES of the last run, RUNS.
"""
import numpy as np

from regs import RegMap, ip_regs

PE = 64                          # MAC array: PE x PE (4096 MACs per clock)
BUS_BYTES = 16                   # DDR bytes per NPU clock
OP_OVERHEAD = 64                 # clocks per descriptor (fetch, set-up, drain)
DESC_BYTES = 64
FLAG_BANK2 = 1 << 8              # word 0: INPUT / DECODE with the second letterbox (geom2)
OP_END, OP_CONV, OP_MAXPOOL, OP_ADD, OP_UPSAMPLE, OP_COPY, OP_INPUT, OP_DECODE, OP_NMS = range(9)
CAND_MAX = 2048                  # NMS candidate buffer (decoded detections of one frame)
DET_WORDS = 4                    # detection record: x0 | x1 << 16, y0 | y1 << 16, class | score << 8 | level << 16, 0


def _i8(a):
    return np.clip(a, -128, 127).astype(np.int8)


class Ddr:
    """Flat byte-addressed DDR model."""

    def __init__(self, size):
        self.mem = np.zeros(size, np.uint8)

    def write(self, addr, data):
        b = np.frombuffer(np.ascontiguousarray(data).tobytes(), np.uint8)
        self.mem[addr:addr + len(b)] = b

    def read(self, addr, n, dtype=np.int8):
        isz = np.dtype(dtype).itemsize
        return self.mem[addr:addr + n * isz].view(dtype).copy()

    def word(self, addr):
        return int(self.mem[addr:addr + 4].view(np.uint32)[0])

    def set_word(self, addr, v):
        self.mem[addr:addr + 4] = np.frombuffer(np.uint32(v & 0xFFFFFFFF).tobytes(), np.uint8)


def bilinear(frame, sw, sh, step):
    """Bilinear scaling (bit-exact, as scaler_bilinear): an sh x sw picture from frame (h x w x 3 uint8),
    STEP frame pixels per output pixel (Q16), pixel centres aligned: source = (x + 1/2) STEP - 1/2,
    clamped to the frame; weights of 8 bits; result (sum + 2^15) >> 16, 0-255. STEP = 1.0 copies."""
    fh, fw = frame.shape[:2]

    def axis(n, lim):
        s = (((2 * np.arange(n, dtype=np.int64) + 1) * step) >> 1) - 32768
        s = np.clip(s, 0, (lim - 1) << 16)
        i0 = s >> 16
        return i0, np.minimum(i0 + 1, lim - 1), (s >> 8) & 255
    y0, y1, fy = axis(sh, fh)
    x0, x1, fx = axis(sw, fw)
    p = frame.astype(np.int64)
    wx0, wx1 = (256 - fx)[None, :, None], fx[None, :, None]
    top = p[y0][:, x0] * wx0 + p[y0][:, x1] * wx1
    bot = p[y1][:, x0] * wx0 + p[y1][:, x1] * wx1
    return (top * (256 - fy)[:, None, None] + bot * fy[:, None, None] + 32768) >> 16


def conv_int8(x, w, bias, mult, shift, stride, pad):
    """INT8 convolution, INT32 accumulation, per-channel requantisation (bit-exact).
    x: C x H x W int8, w: O x C x k x k int8, bias: O int32, mult / shift: O int; returns O x Ho x Wo int64."""
    c, h, wd = x.shape
    o, _, k, _ = w.shape
    xp = np.pad(x.astype(np.float64), ((0, 0), (pad, pad), (pad, pad)))
    ho, wo = (h + 2 * pad - k) // stride + 1, (wd + 2 * pad - k) // stride + 1
    cols = np.empty((c * k * k, ho * wo), np.float64)
    r = 0
    for ci in range(c):
        for dy in range(k):
            for dx in range(k):
                cols[r] = xp[ci, dy:dy + stride * ho:stride, dx:dx + stride * wo:stride].reshape(-1)
                r += 1
    acc = (w.reshape(o, -1).astype(np.float64) @ cols).astype(np.int64) + bias.astype(np.int64)[:, None]
    m = mult.astype(np.int64)[:, None]
    s = shift.astype(np.int64)[:, None]
    q = (acc * m + (np.int64(1) << (s - 1))) >> s           # exact: |acc| < 2^26, m < 2^16
    return q.reshape(o, ho, wo)


class Npu:
    """Command processor + MAC array + DMA on a Ddr; run(desc_addr) executes a command list."""

    def __init__(self, ddr):
        self.ddr = ddr
        self.cycles = 0
        self.ndet = 0
        self.max_det = 256
        self.trace = []                                   # (op, cycles) per descriptor
        self.geom = {}                                    # frame / letterbox registers (INPUT, DECODE)
        self.geom2 = {}                                   # the second letterbox (FLAG_BANK2)

    def tensor(self, addr, c, h, w):
        return self.ddr.read(addr, c * h * w).reshape(c, h, w)

    def run(self, desc, det_addr, max_det):
        """Execute descriptors from desc until END; detections go to det_addr. Returns clocks."""
        self.cycles = 0
        self.ndet = 0
        self.ncand = 0                                    # candidates decoded this run (DECODE -> NMS)
        self.macs = 0
        self.det_addr, self.max_det = det_addr, max_det
        self.trace = []
        while True:
            d = [self.ddr.word(desc + 4 * i) for i in range(16)]
            op = d[0] & 0xFF
            if op == OP_END:
                self.cycles += OP_OVERHEAD
                break
            c = getattr(self, "_op%d" % op)(d)
            c += OP_OVERHEAD
            self.trace.append((op, c))
            self.cycles += c
            desc += DESC_BYTES
        return self.cycles

    @staticmethod
    def _bytes_cycles(n):
        return -(-n // BUS_BYTES)

    def _op1(self, d):                                    # CONV
        cin, hin, win = d[4], d[5] >> 16, d[5] & 0xFFFF
        cout, hout, wout = d[6], d[7] >> 16, d[7] & 0xFFFF
        k, stride, pad = d[8] & 0xFF, (d[8] >> 8) & 0xFF, (d[8] >> 16) & 0xFF
        x = self.tensor(d[1], cin, hin, win)
        w = self.ddr.read(d[9], cout * cin * k * k).reshape(cout, cin, k, k)
        bias = self.ddr.read(d[10], cout, np.int32)
        qv = self.ddr.read(d[11], 2 * cout, np.int32).reshape(cout, 2)
        q = conv_int8(x, w, bias, qv[:, 0], qv[:, 1], stride, pad)
        assert q.shape == (cout, hout, wout), (q.shape, cout, hout, wout)
        q = np.clip(q, -128, 127)
        if d[12]:
            lut = self.ddr.read(d[12], 256)
            q = lut[q + 128]
        self.ddr.write(d[3], _i8(q))
        macs = cout * cin * k * k * hout * wout
        compute = -(-cout // PE) * -(-cin * k * k // PE) * hout * wout
        traffic = cin * hin * win + cout * cin * k * k + 12 * cout + cout * hout * wout
        self.macs += macs
        return max(compute, self._bytes_cycles(traffic))

    def _op2(self, d):                                    # MAXPOOL
        c, h, w = d[4], d[5] >> 16, d[5] & 0xFFFF
        k, stride, pad = d[8] & 0xFF, (d[8] >> 8) & 0xFF, (d[8] >> 16) & 0xFF
        x = self.tensor(d[1], c, h, w).astype(np.int16)
        xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)), constant_values=-129)
        ho, wo = (h + 2 * pad - k) // stride + 1, (w + 2 * pad - k) // stride + 1
        out = np.full((c, ho, wo), -129, np.int16)
        for dy in range(k):
            for dx in range(k):
                out = np.maximum(out, xp[:, dy:dy + stride * ho:stride, dx:dx + stride * wo:stride])
        self.ddr.write(d[3], _i8(out))
        return self._bytes_cycles(c * h * w + c * ho * wo)

    def _op3(self, d):                                    # ADD
        c, h, w = d[4], d[5] >> 16, d[5] & 0xFFFF
        a = self.tensor(d[1], c, h, w).astype(np.int64)
        b = self.tensor(d[2], c, h, w).astype(np.int64)
        ma, mb, s = d[13], d[14], d[15]
        self.ddr.write(d[3], _i8((a * ma + b * mb + (1 << (s - 1))) >> s))
        return self._bytes_cycles(3 * c * h * w)

    def _op4(self, d):                                    # UPSAMPLE x2
        c, h, w = d[4], d[5] >> 16, d[5] & 0xFFFF
        x = self.tensor(d[1], c, h, w)
        self.ddr.write(d[3], np.repeat(np.repeat(x, 2, 1), 2, 2))
        return self._bytes_cycles(5 * c * h * w)

    def _op5(self, d):                                    # COPY
        n = d[4]
        self.ddr.mem[d[3]:d[3] + n] = self.ddr.mem[d[1]:d[1] + n]
        return self._bytes_cycles(2 * n)

    def _op6(self, d):                                    # INPUT: RGB888 frame -> 3 x N x N int8 letterbox
        g = self.geom2 if d[0] & FLAG_BANK2 else self.geom   # the frame and letterbox registers
        fw, fh, stride = g["fw"], g["fh"], g["stride"]
        nw, nh = d[7] & 0xFFFF, (d[7] >> 16) or (d[7] & 0xFFFF)   # the network input, nw x nh
        step = g["step"]                                  # Q16 source pixels per output pixel
        ox, oy = g["ox"], g["oy"]                         # top-left of the picture in the N x N input
        sw, sh = g["sw"], g["sh"]                         # its size
        pad = (d[8] >> 16) & 0xFF
        frame = self.ddr.mem[g["frame"]:g["frame"] + stride * fh].reshape(fh, stride)[:, :fw * 3].reshape(fh, fw, 3)
        out = np.full((3, nh, nw), pad, np.int16)
        pic = bilinear(frame, sw, sh, step) >> 1           # bilinear scaling, then 7 bits
        out[:, oy:oy + sh, ox:ox + sw] = pic.transpose(2, 0, 1)
        self.ddr.write(d[3], _i8(out))
        return self._bytes_cycles(fw * fh * 3 + 3 * nw * nh)

    def _op7(self, d):                                    # DECODE one scale
        reg, nc = d[4] >> 16, d[4] & 0xFFFF
        h, w = d[5] >> 16, d[5] & 0xFFFF
        stride, level = d[8] & 0xFF, (d[8] >> 8) & 0xFF
        box = self.tensor(d[1], 4 * reg, h, w).astype(np.int32).reshape(4, reg, h * w)
        cls = self.tensor(d[2], nc, h, w).astype(np.int32).reshape(nc, h * w)
        exp_lut = self.ddr.read(d[12], 256, np.uint16).astype(np.int64)      # exp(-d * s_box), Q15
        sig_lut = self.ddr.read(d[12] + 512, 256, np.uint8).astype(np.int64)  # sigmoid(q * s_cls), 0-255
        thresh = d[13] - 256 if d[13] & 0x80 else d[13]
        g = self.geom2 if d[0] & FLAG_BANK2 else self.geom
        ox, oy = g["ox"], g["oy"]                                             # letterbox offset (input px)
        inv = g["inv"]                                                        # Q16 frame px per input px
        fw, fh = g["fw"], g["fh"]
        best = cls.max(0)
        bcls = cls.argmax(0)
        keep = np.nonzero(best >= thresh)[0]
        mx = box.max(1, keepdims=True)
        e = exp_lut[np.clip(mx - box, 0, 255)]                                # Q15 weights
        dist = ((e * np.arange(reg)[None, :, None]).sum(1) << 4) // e.sum(1)  # Q4 bins (4 x anchors)
        n_out = 0
        for a in keep:
            if self.ncand >= CAND_MAX:
                break
            ay, ax = divmod(int(a), w)
            cx, cy = (2 * ax + 1) << 3, (2 * ay + 1) << 3                     # anchor centre, Q4 cells
            l, t, r, b = (int(v) for v in dist[:, a])
            coords = []
            for v, o, lim in ((cx - l, ox, fw), (cy - t, oy, fh), (cx + r, ox, fw), (cy + b, oy, fh)):
                p = ((v * stride) >> 4) - o                                   # input px from the picture
                coords.append(min(lim - 1, max(0, (p * inv + (1 << 15)) >> 16)))   # frame px, inside it
            x0, y0, x1, y1 = coords
            rec = d[3] + 4 * DET_WORDS * self.ncand
            self.ddr.set_word(rec, (x0 & 0xFFFF) | (x1 << 16))
            self.ddr.set_word(rec + 4, (y0 & 0xFFFF) | (y1 << 16))
            self.ddr.set_word(rec + 8, int(bcls[a]) | (int(sig_lut[best[a] + 128]) << 8) | (level << 16))
            self.ddr.set_word(rec + 12, 0)
            self.ncand += 1
            n_out += 1
        return self._bytes_cycles((4 * reg + nc) * h * w) + 8 * n_out

    def _op8(self, d):                                    # NMS, foreground first
        n = self.ncand
        recs = self.ddr.read(d[1], DET_WORDS * n, np.uint32).reshape(n, DET_WORDS).astype(np.int64)
        x0, x1 = recs[:, 0] & 0xFFFF, recs[:, 0] >> 16
        y0, y1 = recs[:, 1] & 0xFFFF, recs[:, 1] >> 16
        cls, score = recs[:, 2] & 0xFF, (recs[:, 2] >> 8) & 0xFF
        area = (x1 - x0 + 1) * (y1 - y0 + 1)
        same, other, cont = d[13], d[14], d[15]
        order = sorted(range(n), key=lambda i: (-int(score[i]), i))          # highest score first
        keep = []
        for i in order:
            ok = True
            for j in keep:
                ix = min(x1[i], x1[j]) - max(x0[i], x0[j]) + 1
                iy = min(y1[i], y1[j]) - max(y0[i], y0[j]) + 1
                if ix <= 0 or iy <= 0:
                    continue
                inter = int(ix * iy)
                union = int(area[i] + area[j]) - inter
                lim = same if cls[i] == cls[j] else other
                if inter * 1000 > lim * union:
                    ok = False
                    break
                if cont and cls[i] == cls[j] and inter * 1000 > cont * int(min(area[i], area[j])):
                    ok = False                                              # a part of the same object
                    break
            if ok:
                keep.append(i)
        keep.sort(key=lambda i: (-int(area[i]), -int(score[i]), i))          # foreground (largest) first
        keep = keep[:self.max_det]
        for k, i in enumerate(keep):
            self.ddr.write(self.det_addr + 4 * DET_WORDS * k, recs[i].astype(np.uint32))
        self.ndet = len(keep)
        return n * (len(keep) + 8)                                          # compare pairs, sort


class NpuTop:
    """The NPU IP: registers, frame writer and command processor (Npu) on the DDR shared with the system."""

    def __init__(self, ddr):
        self.ddr = ddr
        self.r = RegMap(ip_regs(__file__, "npu"))
        self.core = Npu(ddr)
        self.runs = 0
        self.cycles = 0                              # clocks of the last run (0: no run on this frame)
        self.frame_ready = False                     # a frame written since the last run (STATUS [1])
        self.r.sts = lambda n, i: {"STATUS": int(self.frame_ready) << 1, "DET_COUNT": self.core.ndet,
                                   "CYCLES": self.cycles & 0xFFFFFFFF, "RUNS": self.runs}.get(n, 0)
        self.r.on_write = self._w

    def _w(self, n, i, d):
        if n == "CMD" and d & 1:
            self.run()

    def frame(self, rgb):
        """A frame from the pipeline: written to DDR (frame writer on), then a run with AUTO."""
        self.cycles = 0
        ctrl = self.r.get("CTRL")
        if ctrl & 1 and ctrl & 4:
            self.write_frame(rgb)
            if ctrl & 2:
                self.run()

    def write_frame(self, rgb):
        """The frame writer: the frame (RGB888) at FRAME_ADDR, FRAME_STRIDE bytes per line."""
        r = self.r
        a, stride = r.get("FRAME_ADDR"), r.get("FRAME_STRIDE")
        h, w = rgb.shape[:2]
        if stride < 3 * w or a + stride * h > len(self.ddr.mem):
            return
        buf = self.ddr.mem[a:a + stride * h].reshape(h, stride)
        buf[:, :3 * w] = np.asarray(rgb, np.uint8).reshape(h, 3 * w)
        self.frame_ready = True

    def run(self):
        """One run: the descriptors at DESC_ADDR on the frame buffer, detections to DET_ADDR."""
        r = self.r
        if not r.get("CTRL") & 1:
            return
        fs = r.get("FRAME_SIZE")
        self.core.geom = dict(frame=r.get("FRAME_ADDR"), stride=r.get("FRAME_STRIDE"), fw=fs & 0xFFFF, fh=fs >> 16,
                              step=r.get("LB_STEP"), ox=r.get("LB_OFFSET") & 0xFFFF, oy=r.get("LB_OFFSET") >> 16,
                              sw=r.get("LB_SIZE") & 0xFFFF, sh=r.get("LB_SIZE") >> 16, inv=r.get("LB_INV"))
        self.core.geom2 = dict(self.core.geom, step=r.get("LB2_STEP"), ox=r.get("LB2_OFFSET") & 0xFFFF,
                               oy=r.get("LB2_OFFSET") >> 16, sw=r.get("LB2_SIZE") & 0xFFFF,
                               sh=r.get("LB2_SIZE") >> 16, inv=r.get("LB2_INV"))
        try:
            self.cycles = self.core.run(r.get("DESC_ADDR"), r.get("DET_ADDR"), r.get("DET_MAX"))
        except (AttributeError, ValueError, AssertionError, IndexError, KeyError):   # bad descriptor / operation
            r.hw_set("IRQ_STATUS", 2)
            self.cycles = OP_OVERHEAD
            return
        self.frame_ready = False
        self.runs += 1
        r.hw_set("IRQ_STATUS", 1)
