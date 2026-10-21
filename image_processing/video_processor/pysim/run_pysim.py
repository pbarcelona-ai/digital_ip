"""video_processor Python-model simulation (make pysim): the counterpart of scripts/run_sim.sh with the
SV testbench replaced by sim.py. For each input (GIF or video in tb/images) a whole system run: the
firmware boots, runs sections 1-7, then tracks the input (section 8) and prints its summary.

By default every real-life input of tb/images is run; the generated GIFs (a <name>.truth.txt beside them,
from tb/scripts/make_*_gif.py) only with --synthetic.

Outputs, per input <name>, in --out (default python-prototype/):
  <name>_pysim.gif / .mp4          frames out of the overlay (HDMI); the MP4 2x for frames under 640 wide
  <name>_pysim_sheet.png           contact sheet of the output frames
  <name>_pysim_transcript.txt      the firmware's report (UART 0 or the direct transcript port)
  <name>_pysim_log.txt             the run: options, stage timeline, and the overlay objects of every
                                   output frame (label, class colour, box)
Options as run_sim.sh: --gif-frames (--frames), --gif-first, --video-fps, --video-start, --gif-bw,
--detect, --box, --targets, --direct-log; --jobs runs inputs in parallel processes.
"""
import argparse
import glob
import os
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN = os.path.dirname(HERE)
IMAGES = os.path.join(DESIGN, "tb", "images")
sys.path.insert(0, HERE)

import sim                                    # noqa: E402  (puts the models of scripts/build.f on sys.path)
import symbol_overlay_model                   # noqa: E402

VIDEO_EXT = (".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm")
CLASS_NAMES = {"pedestrian": 0, "pedestrians": 0, "person": 0, "p": 0, "1": 0,
               "face": 1, "faces": 1, "f": 1, "2": 1,
               "automobile": 2, "car": 2, "a": 2,
               "vehicle": 3, "bus": 3, "truck": 3, "v": 3,
               "aircraft": 4, "plane": 4, "planes": 4, "air": 4}
STYLES = {"dashed-box": 0, "box-dashed": 0, "dashed": 0, "solid-box": 1, "box-solid": 1, "box": 1,
          "solid": 1, "dashed-circle": 2, "circle-dashed": 2, "solid-circle": 3, "circle-solid": 3,
          "circle": 3, "dashed-oval": 4, "oval-dashed": 4, "solid-oval": 5, "oval-solid": 5, "oval": 5,
          "solid-centre": 6, "solid-center": 6, "centre-box": 6, "center-box": 6, "centre": 6,
          "corner-box": 7, "tick-box": 8, "triangle": 9}
# defaults: people (pedestrian, face) white dashed box with solid corners, ground transport (automobile,
# vehicle) the same with 2-pixel ticks, aircraft a green dashed triangle with solid vertices
DEFAULT_STYLES = [7, 7, 8, 8, 9]
ALL_CLASSES = 0x1F
MAX_TARGETS = 32                              # the firmware's NOBJ_MAX: 32 overlay objects (NPU tracks)


def parse_detect(s):
    mask = 0
    for item in (t.strip().lower() for t in s.split(",") if t.strip()):
        if item == "all":
            mask = ALL_CLASSES
        elif item in ("vehicles", "3", "ground"):
            mask |= 0b01100
        elif item in CLASS_NAMES:
            mask |= 1 << CLASS_NAMES[item]
        else:
            raise SystemExit(f"--detect: unknown class {item} (pedestrian, face, automobile, vehicle, "
                             "aircraft, vehicles, all)")
    return mask or 1


def parse_box(s, styles):
    styles = list(styles)
    for item in (t.strip().lower() for t in s.split(",") if t.strip()):
        cls, _, st = item.rpartition(":")
        if st not in STYLES:
            raise SystemExit(f"--box: unknown style {st} ({', '.join(sorted(set(STYLES)))})")
        if not cls:
            styles = [STYLES[st]] * len(styles)
        elif cls in ("vehicles", "3", "ground"):
            styles[2] = styles[3] = STYLES[st]
        elif cls in CLASS_NAMES:
            styles[CLASS_NAMES[cls]] = STYLES[st]
        else:
            raise SystemExit(f"--box: unknown class {cls}")
    return styles


def overlay_objects(vsys):
    """(label, colour, (x0, x1, y0, y1)) of every enabled overlay object of the frame just drawn."""
    a = vsys.ovl.active or {}
    out = []
    for i in range(symbol_overlay_model.NOBJ):
        ctrl = symbol_overlay_model.obj_key(a, "OBJ_CTRL", i)
        if not ctrl & 1:
            continue
        xv, yv = symbol_overlay_model.obj_key(a, "OBJ_X", i), symbol_overlay_model.obj_key(a, "OBJ_Y", i)
        lab = symbol_overlay_model.obj_key(a, "OBJ_LABEL", i)
        text = bytes((lab >> (8 * k)) & 0xFF for k in range(4)).rstrip(b"\0").decode("latin-1")
        out.append((text or f"#{i}", symbol_overlay_model.obj_key(a, "OBJ_COLOR", i) & 0xFFFFFF,
                    (xv & 0xFFFF, xv >> 16, yv & 0xFFFF, yv >> 16)))
    return out


def run_one(path, a):
    """One whole system run for one input; returns a one-line summary."""
    import numpy as np
    from PIL import Image
    import mp4_io
    import detect_proto
    inp = sim.Input(path, a.video_fps, a.video_start, a.frames or 100, a.gif_first, a.frames, a.gif_bw, a.fit)
    name = inp.name
    out = a.out
    fw = a.fw
    log_lines = []

    def log(s):
        log_lines.append(s)
        if a.verbose:
            print(f"[{name}] {s}", flush=True)

    tr = open(os.path.join(out, f"{name}_pysim_transcript.txt"), "w")
    prog = None
    if a.npu_prog:
        import npu_compiler
        prog = npu_compiler.load_program(a.npu_prog[path])
    system = sim.System(fw, quick=not a.full, direct=a.direct_log, transcript=tr, npu_prog=prog)
    t0 = time.time()
    log(f"input {path}: {len(inp.frames)} frames of {inp.w} x {inp.h} ({'monochrome' if inp.mono else 'colour'})")
    log(f"detect mask 0x{a.det_mask:02X}, styles {a.styles}, most targets {a.targets}, "
        f"{'quick' if not a.full else 'full'} start-up, transcript on {'GPIO1' if a.direct_log else 'UART 0'}")
    last = [None]

    def on_event():
        st = system.g("stage")
        if st != last[0]:
            last[0] = st
            log(f"  {system.sim.now / 200:12.1f} us  wall {time.time() - t0:7.1f} s  firmware stage {st}")
    system.sim.on_event = on_event

    def on_frame(k, _img):
        objs = overlay_objects(system.vsys)
        log(f"  frame {k + 1:3d}: " + (", ".join(f"{t} {c:06X} x {b[0]}-{b[1]} y {b[2]}-{b[3]}"
                                                for t, c, b in objs) or "no objects"))
    system.on_frame = on_frame
    status = "ok"
    try:
        results = system.run([inp], a.styles, a.det_mask, a.targets, log=log, max_seconds=a.max_seconds)
    except Exception as e:                    # the run's end and the error go into the log
        status = f"ERROR {e}"
        log(status)
        log(traceback.format_exc())
        results = [(inp, list(system.captured), list(system.tracker_in))]
    finally:
        tr.close()
    frames = results[0][1] if results else []
    log(f"stage {system.g('stage')} at the end, {len(frames)} output frames, "
        f"sim {system.sim.now / 200e6:.3f} s, wall {time.time() - t0:.1f} s")
    if frames:
        fps = 1000.0 / max(1, sum(inp.delays) / len(inp.delays))
        mp4_io.write_gif([Image.fromarray(np.asarray(f, np.uint8)) for f in frames],
                         os.path.join(out, f"{name}_pysim.gif"), fps, mp4_io.OVERLAY_COLOURS)
        k = 2 if inp.w < 640 else 1                   # small frames scaled up 2x (nearest) in the MP4
        big = [Image.fromarray(np.asarray(f, np.uint8)).resize((inp.w * k, inp.h * k), Image.NEAREST)
               for f in frames]
        mp4_io.write_mp4(big, list(inp.delays[:len(frames)]), os.path.join(out, f"{name}_pysim.mp4"))
        detect_proto.sheet([np.asarray(f, np.uint8) for f in frames], os.path.join(out, f"{name}_pysim_sheet.png"))
    if len(frames) < len(inp.frames) and status == "ok":
        status = f"ERROR {len(frames)} of {len(inp.frames)} frames out"
        log(status)
    with open(os.path.join(out, f"{name}_pysim_log.txt"), "w") as fh:
        fh.write("\n".join(log_lines) + "\n")
    with open(os.path.join(out, f"{name}_pysim_transcript.txt"), encoding="latin-1") as fh:
        transcript = fh.read()
    passed = transcript.count("[PASS]")
    failed = transcript.count("[FAIL]")
    return (f"{name:45s} {status:6.40s} {len(frames):3d}/{len(inp.frames):3d} frames  "
            f"{passed} PASS {failed} FAIL  {time.time() - t0:7.1f} s")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", help="GIFs / videos (default: every real-life one in tb/images)")
    ap.add_argument("--synthetic", action="store_true", help="by default also the generated GIFs (those with a "
                    "<name>.truth.txt from tb/scripts/make_*_gif.py)")
    ap.add_argument("--out", default=os.path.join(DESIGN, "python-prototype"))
    ap.add_argument("--build", default=os.path.join(DESIGN, "build", "pysim"), help="firmware build directory")
    ap.add_argument("--frames", "--gif-frames", type=int, default=0, help="at most this many frames (default all)")
    ap.add_argument("--gif-first", type=int, default=0, help="first frame sent")
    ap.add_argument("--video-fps", type=float, default=10.0)
    ap.add_argument("--video-start", type=float, default=0.0)
    ap.add_argument("--gif-bw", action="store_true", help="send the input monochrome")
    ap.add_argument("--detect", default="all", help="classes: pedestrian, face, automobile, vehicle, aircraft, "
                    "vehicles, all (comma separated)")
    ap.add_argument("--box", default="", help="<style> or <class>:<style>,... (default: see DEFAULT_STYLES)")
    ap.add_argument("--targets", type=int, default=32, help="most targets at a time (1-32: the overlay objects)")
    ap.add_argument("--direct-log", action="store_true", help="transcript on the GPIO1 direct port")
    ap.add_argument("--full", action="store_true", help="no quick-simulation strap (whole start-up report)")
    ap.add_argument("--max-seconds", type=float, default=7200, help="wall-clock limit per input")
    ap.add_argument("--jobs", type=int, default=1, help="inputs run in parallel")
    ap.add_argument("--clean", action="store_true", help="delete earlier *_pysim* outputs in --out first")
    ap.add_argument("--weights", default=os.path.join(DESIGN, "build", "models", "yolov8s.pt"),
                    help="detector compiled for the NPU (ip/ai/npu/scripts/npu_compiler.py)")
    ap.add_argument("--no-npu", action="store_true", help="no NPU program in DDR (the firmware's feature detectors)")
    ap.add_argument("--fit", default="native", help="camera frames fitted inside WxH, or native: each input at its "
                    "own size up to 1920x1080 / 1080x1920 (default; the SV testbench uses 320x240)")
    ap.add_argument("--n", type=int, default=0, help="NPU network input n x n (a multiple of 32); 0 (default): "
                    "each input's frame size rounded up to multiples of 32 (a program per size)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    a.det_mask = parse_detect(a.detect)
    a.fit = None if a.fit == "native" else tuple(int(v) for v in a.fit.lower().split("x"))
    a.styles = parse_box(a.box, DEFAULT_STYLES)
    if not 1 <= a.targets <= MAX_TARGETS:
        raise SystemExit(f"--targets: 1 to {MAX_TARGETS}")
    ins = a.inputs or sorted(f for f in glob.glob(os.path.join(IMAGES, "*"))
                             if f.lower().endswith((".gif",) + VIDEO_EXT)
                             and (a.synthetic or not os.path.exists(os.path.splitext(f)[0] + ".truth.txt")))
    os.makedirs(a.out, exist_ok=True)
    a.fw = sim.build_firmware(a.build)                # once: every input runs the same firmware
    a.npu_prog = None
    if not a.no_npu:                                  # the NPU program, compiled once (cached)
        import npu_compiler
        real = sorted(f for f in glob.glob(os.path.join(IMAGES, "*")) if f.lower().endswith((".gif",) + VIDEO_EXT)
                      and not os.path.exists(os.path.splitext(f)[0] + ".truth.txt"))
        a.npu_prog = {}                                # input -> its program (one per network input size)
        for p in ins:
            if a.n:
                nw = nh = a.n
            else:
                probe = sim.Input(p, a.video_fps, a.video_start, 1, 0, 1, False, a.fit)
                nw, nh = npu_compiler.shape_for(probe.w, probe.h)
            stem = os.path.splitext(os.path.basename(a.weights))[0]
            cache = os.path.join(a.build, f"npu_prog_{stem}_{nw}x{nh}.npz")
            npu_compiler.program(a.weights, real, cache, n=(nw, nh))
            a.npu_prog[p] = cache
    if a.clean:
        for f in glob.glob(os.path.join(a.out, "*_pysim*")):
            os.remove(f)
    summary = []
    if a.jobs > 1 and len(ins) > 1:
        with ProcessPoolExecutor(a.jobs) as ex:
            futs = {ex.submit(run_one, p, a): p for p in ins}
            for f in as_completed(futs):
                try:
                    line = f.result()
                except Exception as e:
                    line = f"{os.path.basename(futs[f]):45s} ERROR {e}"
                print(line, flush=True)
                summary.append(line)
    else:
        for p in ins:
            line = run_one(p, a)
            print(line, flush=True)
            summary.append(line)
    with open(os.path.join(a.out, "pysim_summary.txt"), "w") as fh:
        fh.write("\n".join(sorted(summary)) + "\n")
    return 1 if any(" ERROR" in s for s in summary) else 0


if __name__ == "__main__":
    sys.exit(main())
