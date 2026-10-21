"""Reference detection and tracking for the video_processor inputs (not a hardware model).

Runs an Ultralytics YOLOv8 detector (YOLOv8s by default; floating point, PyTorch) with its ByteTrack tracker on the same frames the
testbench sends (sim.Input: GIF / video fitted to 320 x 240, the testbench's colours), and draws the result
the way the overlay does (constant 17-pixel symbols, labels below). It is the target the NPU model and the
firmware's ByteTrack-type tracker are measured against.

Outputs per input <name> in --out (default python-prototype/reference/): <name>_ref.gif, <name>_ref_sheet.png,
<name>_ref_log.txt (per frame: track id, class, score, box).
Usage: reference_track.py [--weights build/models/yolov8s.pt] [--imgsz 0] [--conf 0.25] [inputs...]
"""
import argparse
import glob
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import run_pysim                              # noqa: E402
import sim                                    # noqa: E402  (puts the models of scripts/build.f on sys.path)
import symbol_overlay_model                   # noqa: E402

# COCO class -> overlay group: P person, G ground transport, A aircraft, O any other object
GROUND = {"bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"}
GROUP_COLOUR = {"P": (255, 255, 255), "G": (255, 0, 0), "A": (0, 255, 0), "O": (255, 255, 0)}   # R, G, B


def group_of(name):
    if name == "person":
        return "P"
    if name == "airplane":
        return "A"
    if name in GROUND:
        return "G"
    return "O"


def draw(frame, tracks):
    """Overlay-style symbols: dashed box with solid corners (P, O), with ticks (G), triangle (A); label."""
    out = frame.copy()
    h, w = out.shape[:2]
    for tid, grp, _name, _score, (x0, y0, x1, y1) in tracks:
        cx, cy = int((x0 + x1) / 2), int((y0 + y1) / 2)
        bx0 = min(max(cx - 8, 0), w - 17)
        by0 = min(max(cy - 8, 0), h - 17)
        box = (bx0, bx0 + 16, by0, by0 + 16)
        ctrl = 1 | 8 | (2 << 12) | (1 << 15)                  # box, dashed, dashes of 4, solid corners
        if grp == "G":
            ctrl |= 1 << 6                                    # ticks
        if grp == "A":
            ctrl = 1 | 8 | (2 << 12) | (1 << 7)               # triangle
        col = np.array(GROUP_COLOUR[grp], np.uint8)
        out[symbol_overlay_model.symbol_mask(ctrl, box, w, h)] = col
        text = f"{grp}{tid}"[:4].encode("ascii")
        symbol_overlay_model.draw_label(out, int.from_bytes(text.ljust(4, b"\0"), "little"), box, col, 2)
    return out


def run(path, a, model):
    from PIL import Image
    import mp4_io
    import detect_proto
    inp = sim.Input(path, a.video_fps, 0.0, a.frames or 100, 0, a.frames, False, a.fit)
    model.predictor = None                                    # a fresh tracker per input
    frames, log = [], [f"input {path}: {len(inp.frames)} frames of {inp.w} x {inp.h}, {os.path.basename(a.weights)} imgsz {a.imgsz or 'native'} "
                        f"conf {a.conf}, ByteTrack (Ultralytics reference)"]
    ids = {}                                                  # tracker id -> group number (1..n per group)
    for k, rgb in enumerate(inp.frames):
        isz = a.imgsz or [((inp.h + 31) // 32) * 32, ((inp.w + 31) // 32) * 32]   # as the NPU: native size
        r = model.track(rgb[..., ::-1], persist=True, tracker="bytetrack.yaml", imgsz=isz, conf=a.conf,
                        verbose=False)[0]
        tracks = []
        if r.boxes is not None and r.boxes.id is not None:
            for tid, c, s, b in zip(r.boxes.id.int().tolist(), r.boxes.cls.int().tolist(),
                                    r.boxes.conf.tolist(), r.boxes.xyxy.tolist()):
                name = model.names[c]
                grp = group_of(name)
                if tid not in ids:
                    used = {n for (g, n) in ids.values() if g == grp}
                    n = 1
                    while n in used:
                        n += 1
                    ids[tid] = (grp, n)
                tracks.append((ids[tid][1], grp, name, s, b))
        frames.append(draw(rgb, tracks))
        log.append(f"  frame {k + 1:3d}: " + (", ".join(f"{g}{n} {name} {s:.2f} x {b[0]:.0f}-{b[2]:.0f} y "
                                                     f"{b[1]:.0f}-{b[3]:.0f}" for n, g, name, s, b in tracks)
                                            or "no objects"))
    base = os.path.join(a.out, f"{inp.name}_ref")
    fps = 1000.0 / max(1, sum(inp.delays) / len(inp.delays))
    mp4_io.write_gif([Image.fromarray(f) for f in frames], base + ".gif", fps, mp4_io.OVERLAY_COLOURS)
    detect_proto.sheet(frames, base + "_sheet.png")
    with open(base + "_log.txt", "w", encoding="utf-8") as fh:
        fh.write("\n".join(log) + "\n")
    return f"{inp.name:45s} {len(frames):3d} frames, {len(ids)} tracks"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*")
    ap.add_argument("--weights", default=os.path.join(DESIGN, "build", "models", "yolov8s.pt"))
    ap.add_argument("--imgsz", type=int, default=0, help="network input (0: the frame's longer side)")
    ap.add_argument("--fit", default="native", help="frames fitted inside WxH, or native (as make pysim)")
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--frames", type=int, default=0)
    ap.add_argument("--video-fps", type=float, default=10.0)
    ap.add_argument("--out", default=os.path.join(DESIGN, "python-prototype", "reference"))
    a = ap.parse_args()
    a.fit = None if a.fit == "native" else tuple(int(v) for v in a.fit.lower().split("x"))
    from ultralytics import YOLO
    model = YOLO(a.weights)
    ins = a.inputs or sorted(f for f in glob.glob(os.path.join(run_pysim.IMAGES, "*"))
                             if f.lower().endswith((".gif",) + run_pysim.VIDEO_EXT)
                             and not os.path.exists(os.path.splitext(f)[0] + ".truth.txt"))
    os.makedirs(a.out, exist_ok=True)
    for p in ins:
        print(run(p, a, model), flush=True)


if __name__ == "__main__":
    main()
