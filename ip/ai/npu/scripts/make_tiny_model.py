# ***************
# Filename: make_tiny_model.py
# Author: FPGA Cores 4 U
# Description: Builds the NPU's system-test network: a YOLOv8 DetectionModel scaled down (depth 0.33, width
#   1/16, 5 classes: COCO 0-4 person, bicycle, car, motorcycle, airplane) with seeded random weights, saved as
#   an Ultralytics checkpoint that npu_compiler.py compiles like a trained one. The network exercises every
#   NPU operation of the real detector (INPUT, CONV + SiLU, MAXPOOL, ADD, UPSAMPLE, concatenation, DECODE,
#   NMS) at a fraction of its work (about 30 M MACs, 72 k NPU clocks at 128 x 128), so a system simulation can run it on
#   every frame. Untrained detections mean nothing; they only have to be the same in the RTL and the
#   model. The class biases are set so that, on the calibration frames, about TOP percent of the anchors
#   score above the threshold for the classes in --classes (default person and car) and none for the
#   others: a few candidates per frame, so DECODE and NMS have work and the tracker gets targets.
#   Deterministic: the same seed and frames give the same checkpoint.
# Date: 2026-10-26
# ***************
"""Usage: python3 ip/ai/npu/scripts/make_tiny_model.py --out <file.pt> [--n 128] [--seed 1] [--classes 0,2]
[--top 1.5] [--conf 0.1] [frames.gif ...]  (frames: calibration inputs for the class biases; default none:
biases from random frames)."""
import argparse
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

NAMES = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 4: "airplane"}   # COCO classes 0-4
BOX_SLOPE = 0.8                                # box bin bias per bin (see tune_biases)


def build(seed):
    """The scaled-down YOLOv8 with seeded random weights (BatchNorm at its defaults)."""
    import torch
    import ultralytics
    import yaml
    from ultralytics.nn.tasks import DetectionModel
    with open(os.path.join(os.path.dirname(ultralytics.__file__), "cfg", "models", "v8", "yolov8.yaml")) as fh:
        cfg = yaml.safe_load(fh)
    cfg["nc"] = len(NAMES)
    cfg["scales"] = {"t": [0.33, 0.0625, 1024]}
    cfg["scale"] = "t"
    torch.manual_seed(seed)
    m = DetectionModel(cfg, ch=3, nc=len(NAMES), verbose=False)
    m.names = dict(NAMES)
    return m.float().eval()


def batch(frames, n):
    """The frames letterboxed to n x n as the model's input (N x 3 x n x n, 0 .. 1)."""
    import torch
    import npu_compiler
    x = np.stack([npu_compiler.letterbox(rgb, n, n).astype(np.float32) / 255.0 for rgb in frames])
    return torch.from_numpy(np.ascontiguousarray(x.transpose(0, 3, 1, 2)))


def unit_scale(m, frames, n, passes=2):
    """Data-driven rescale (LSUV): in forward order, each convolution's weights scaled so its output has a
    standard deviation of 1 on the frames. Random weights alone shrink the activations layer by layer
    (the output stops depending on the input); after this every layer carries the frame's content."""
    import torch
    import torch.nn as nn
    x = batch(frames, n)
    # (not the Detect head's DFL: a fixed, frozen convolution - the bin index weights of the box decode)
    convs = [c for c in m.modules() if isinstance(c, nn.Conv2d) and c.weight.requires_grad]
    with torch.no_grad():
        for _ in range(passes):
            for cv in convs:
                out = []
                h = cv.register_forward_hook(lambda _m, _i, o: out.append(o))
                m(x)
                h.remove()
                s = float(out[0].std())
                if s > 1e-12:
                    cv.weight /= s
                    if cv.bias is not None:
                        cv.bias /= s


def class_logits(m, frames, n):
    """The class convolutions' outputs (logits, per class over every anchor of every level and frame)."""
    import torch
    det = m.model[-1]
    got = []
    hooks = [det.cv3[lvl][2].register_forward_hook(lambda _m, _i, o: got.append(o.detach()))
             for lvl in range(det.nl)]
    with torch.no_grad():
        m(batch(frames, n))
    for h in hooks:
        h.remove()
    return np.concatenate([g.numpy().transpose(1, 0, 2, 3).reshape(det.nc, -1) for g in got], axis=1)


def tune_biases(m, frames, n, classes, top, conf):
    """Bias offsets: the box bins biased towards short distances (BOX_SLOPE); for each class in classes the
    (100 - top) percentile of its logits lands just above the threshold's logit; every other class far below
    it."""
    import torch
    det = m.model[-1]
    logits = class_logits(m, frames, n)
    thr = math.log(conf / (1.0 - conf)) + 0.5
    with torch.no_grad():
        # box distributions (reg_max bins per side): bin j biased by -BOX_SLOPE j, so a side is a few bins
        # (a stride or two) instead of the random mean of reg_max / 2 bins (boxes over the whole frame)
        for lvl in range(det.nl):
            det.cv2[lvl][2].bias -= BOX_SLOPE * torch.arange(det.reg_max, dtype=torch.float32).repeat(4)
        for c in range(det.nc):
            off = thr - float(np.percentile(logits[c], 100.0 - top)) if c in classes else -12.0 - float(logits[c].max())
            for lvl in range(det.nl):
                det.cv3[lvl][2].bias[c] += off


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=128, help="network input n x n the biases are tuned at")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--classes", default="0,2", help="classes that get candidates (COCO 0-4)")
    ap.add_argument("--top", type=float, default=1.5, help="percent of the anchors above the threshold")
    ap.add_argument("--conf", type=float, default=0.1, help="the program's score threshold (npu_compiler)")
    ap.add_argument("--fit", default="320x240", help="calibration frames fitted inside WxH (the TB's size)")
    ap.add_argument("inputs", nargs="*", help="GIFs / videos for the class biases")
    a = ap.parse_args()
    if not 0.0 < a.top < 100.0 or not 0.0 < a.conf < 1.0 or a.n <= 0 or a.n % 32:
        ap.error("--top in (0, 100), --conf in (0, 1), --n a positive multiple of 32")
    import torch
    m = build(a.seed)
    classes = {int(c) for c in a.classes.split(",") if c}
    if a.inputs:
        import sim                                    # the calling design's pysim (on PYTHONPATH)
        fw, fh = (int(v) for v in a.fit.split("x"))
        frames = []
        for p in a.inputs:
            d = sim.Input(p, 10.0, 0.0, 8, 0, 8, False, (fw, fh))
            frames += list(d.frames)
    else:
        rng = np.random.default_rng(a.seed)
        frames = [rng.integers(0, 256, (240, 320, 3), dtype=np.uint8) for _ in range(4)]
    unit_scale(m, frames, a.n)
    tune_biases(m, frames, a.n, classes, a.top, a.conf)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    torch.save({"model": m, "train_args": {}, "epoch": -1, "date": "2026-10-26"}, a.out)
    print(f"make_tiny_model: {a.out}: {sum(p.numel() for p in m.parameters())} parameters, classes "
          f"{sorted(classes)} tuned on {len(frames)} frames")


if __name__ == "__main__":
    main()
