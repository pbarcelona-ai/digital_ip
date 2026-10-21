"""Fast algorithm loop for the video_processor tracking (not the system simulation: make pysim is).

The firmware's own source (sw/video_proc.py and the modules it imports, inlined into one namespace as
pyc.py does) runs natively on CPython against the same block models as make pysim (py_soc_model, video_processor_model):
mem32 is mapped onto the models' register windows, there is no py_core model, no boot, no transcript
and no timing. The video set-up (video_setup) and the tracking set-up run as in section 8, then for
every input frame the pipeline models process it and the firmware's track_event() runs on the result.
Detection and tracking come out as in make pysim (the same code and register values) in a fraction of
the time, for trying algorithm changes on every input; make pysim then confirms them.

Waits and interrupt builtins are stubs (wait_bit returns at once, wait_irq / irq_* do nothing), the
camera's I2C answers are not used (the frame size, classes, styles and name are set directly), and
py_core's 33-bit overflow trap is not checked.

Outputs per input <name> in --out: <name>_fast.gif, <name>_fast_sheet.png, <name>_fast_log.txt (the
overlay objects of every output frame, as make pysim's log).
Usage: fastsim.py [--out DIR] [--frames N] [--jobs N] [inputs...]   (default: every real-life input)
"""
import argparse
import glob
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN = os.path.dirname(HERE)
ROOT = os.path.abspath(os.path.join(DESIGN, "..", ".."))
sys.path.insert(0, HERE)

import sim                                    # noqa: E402  (puts the models of scripts/build.f on sys.path)
import run_pysim                              # noqa: E402
from board import Board                       # noqa: E402
from event_sim import Sim                     # noqa: E402
from py_soc_model import Soc                  # noqa: E402

PYC = os.path.join(ROOT, "ip", "cpu", "py_core", "tools", "pyc.py")
SV_INC = [os.path.join(DESIGN, "src"), os.path.join(ROOT, "ip", "cpu", "py_soc", "src"),
          os.path.join(ROOT, "ip", "video", "video_pipeline", "src")]


def firmware_source():
    """sw/video_proc.py with its imports inlined (pyc.py inline_imports), without the machine import and
    the program's start (main() and the idle loop)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("pyc", PYC)
    pyc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pyc)
    pyc.SV_PATH[:] = SV_INC
    lines, _ = pyc.inline_imports(os.path.join(DESIGN, "sw", "video_proc.py"))
    end = max(i for i, ln in enumerate(lines) if ln == "main()")
    return "\n".join(ln for ln in lines[:end] if not re.match(r"\s*from\s+machine\s+import", ln)) + "\n"


class Mem32:
    """mem32[addr]: the 32-bit register at addr through the SoC's address decoder (read / write)."""

    def __init__(self, soc):
        self.soc = soc

    def __getitem__(self, addr):
        d, ok = self.soc.read(addr)
        if not ok:
            raise RuntimeError(f"bus error reading 0x{addr:X}")
        return d & 0xFFFFFFFF

    def __setitem__(self, addr, v):
        if not self.soc.write(addr, v & 0xFFFFFFFF):
            raise RuntimeError(f"bus error writing 0x{addr:X}")


def firmware(soc, source):
    """The firmware's namespace on these models, with the builtins and waits as stubs."""
    ns = {"__name__": "firmware", "mem32": Mem32(soc), "strings": lambda *a: 0}   # strings(): module level too
    exec(compile(source, "firmware", "exec"), ns)       # noqa: S102 - the project's own firmware source
    for name in ("irq_handler", "irq_enable", "irq_disable", "wait_irq", "sleep_until", "pause"):
        ns[name] = lambda *a: None
    ns["wait_bit"] = lambda *a: 1
    ns["con"] = 0                                     # no text
    ns["log_wr"] = 0
    return ns


def run(path, a, source):
    import numpy as np
    from PIL import Image
    import mp4_io
    import detect_proto
    t0 = time.time()
    inp = sim.Input(path, a.video_fps, a.video_start, a.frames or 100, 0, a.frames, False, a.fit)
    s = Sim(200_000_000)
    board = Board(quick=True)
    soc = Soc(s, b"", board)
    vsys = sim.video_processor_model.VideoSystem(s, soc)
    soc.ext = vsys
    soc.ddr = vsys.ddr
    if a.npu_prog:
        import npu_compiler
        npu_compiler.load_into(vsys.ddr, npu_compiler.load_program(a.npu_prog[path]))
    ns = firmware(soc, source)
    board.cam_reset_n = 1
    ns["video_setup"]()
    board.mono = inp.mono
    ns["set_format"]()
    # section 8 set-up (track_setup without the camera's I2C answers and the report)
    styles = run_pysim.DEFAULT_STYLES
    ns["cam_w"], ns["cam_h"] = inp.w, inp.h
    ns["det_mask"] = a.det_mask
    ns["det_style"] = sum(st << (4 * c) for c, st in enumerate(styles))
    ns["max_targets"] = a.targets
    ns["frame_size"](inp.w, inp.h)
    m = ns["mem32"]
    m[ns["VP"] + ns["VP_CTRL"]] = ns["CTRL_ENABLE"] | ns["CTRL_HDMI"] | ns["CTRL_LOCK"] | ns["CTRL_INSERT"]
    ns["tracker_setup"]()
    ns["feature_setup"]()
    c = 0
    while not a.det_mask & (1 << c):
        c += 1
    ns["first_cls"] = ns["det_base"](c)
    ns["detector_select"]()                           # the NPU and ByteTrack when its program is in DDR
    name = inp.name.encode("ascii", "replace")[:16]
    for q in range(4):                                # the image name into T_NAME's characters
        w = int.from_bytes(name[4 * q:4 * q + 4].ljust(4, b"\0"), "little")
        ns["text_word"](ns["T_NAME"], q, w)
    ns["overlay_setup"](len(name))
    ns["trk_frames"] = ns["trk_found"] = 0
    ns["trk_base"] = m[ns["first_cls"] + ns["TRK_FRAMES"]]
    if ns["npu_mode"]:
        ns["trk_base"] = m[ns["NPU"] + ns["N_RUNS"]]
    frames, log = [], [f"input {path}: {len(inp.frames)} frames of {inp.w} x {inp.h} "
                       f"({'monochrome' if inp.mono else 'colour'}), fastsim (firmware on CPython)"]
    line = int(max(inp.w * 11.5, 2.0 * inp.w + 200) * sim.NS)
    for k, rgb in enumerate(inp.frames):
        out, _, _ = vsys.process(sim.to_raw(rgb, inp.mono), None)
        frames.append(out)
        objs = run_pysim.overlay_objects(vsys)
        log.append(f"  frame {k + 1:3d}: " + (", ".join(f"{t} {col:06X} x {b[0]}-{b[1]} y {b[2]}-{b[3]}"
                                                     for t, col, b in objs) or "no objects"))
        s.advance(inp.h * line + 2000)                 # the clock text moves on by a frame time
        if ns["npu_mode"]:
            ns["track_event"](m[ns["NPU"] + ns["N_RUNS"]] - ns["trk_base"])
        else:
            ns["track_event"](m[ns["first_cls"] + ns["TRK_FRAMES"]] - ns["trk_base"])
    fps = 1000.0 / max(1, sum(inp.delays) / len(inp.delays))
    base = os.path.join(a.out, f"{inp.name}_fast")
    mp4_io.write_gif([Image.fromarray(np.asarray(f, np.uint8)) for f in frames], base + ".gif", fps, mp4_io.OVERLAY_COLOURS)
    detect_proto.sheet([np.asarray(f, np.uint8) for f in frames], base + "_sheet.png")
    with open(base + "_log.txt", "w") as fh:
        fh.write("\n".join(log) + "\n")
    return f"{inp.name:45s} {len(frames):3d} frames  {time.time() - t0:6.1f} s"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*")
    ap.add_argument("--out", default=os.path.join(DESIGN, "build", "fastsim"))
    ap.add_argument("--frames", type=int, default=0)
    ap.add_argument("--video-fps", type=float, default=10.0)
    ap.add_argument("--video-start", type=float, default=0.0)
    ap.add_argument("--detect", default="all")
    ap.add_argument("--targets", type=int, default=32)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--weights", default=os.path.join(DESIGN, "build", "models", "yolov8s.pt"))
    ap.add_argument("--no-npu", action="store_true")
    ap.add_argument("--fit", default="native", help="camera frames fitted inside WxH, or native (up to 1920x1080)")
    ap.add_argument("--n", type=int, default=0, help="NPU network input n x n; 0: each input's size rounded up to 32")
    a = ap.parse_args()
    a.det_mask = run_pysim.parse_detect(a.detect)
    a.fit = None if a.fit == "native" else tuple(int(v) for v in a.fit.lower().split("x"))
    ins = a.inputs or sorted(f for f in glob.glob(os.path.join(run_pysim.IMAGES, "*"))
                             if f.lower().endswith((".gif",) + run_pysim.VIDEO_EXT)
                             and not os.path.exists(os.path.splitext(f)[0] + ".truth.txt"))
    os.makedirs(a.out, exist_ok=True)
    source = firmware_source()
    a.npu_prog = None
    if not a.no_npu:
        import npu_compiler
        real = sorted(f for f in glob.glob(os.path.join(run_pysim.IMAGES, "*"))
                      if f.lower().endswith((".gif",) + run_pysim.VIDEO_EXT)
                      and not os.path.exists(os.path.splitext(f)[0] + ".truth.txt"))
        a.npu_prog = {}                                # input -> its program (one per network input size)
        for p in ins:
            if a.n:
                nw = nh = a.n
            else:
                probe = sim.Input(p, a.video_fps, a.video_start, 1, 0, 1, False, a.fit)
                nw, nh = npu_compiler.shape_for(probe.w, probe.h)
            stem = os.path.splitext(os.path.basename(a.weights))[0]
            cache = os.path.join(os.path.join(DESIGN, "build", "pysim"), f"npu_prog_{stem}_{nw}x{nh}.npz")
            npu_compiler.program(a.weights, real, cache, n=(nw, nh))
            a.npu_prog[p] = cache
    if a.jobs > 1 and len(ins) > 1:
        with ProcessPoolExecutor(a.jobs) as ex:
            for line in ex.map(run, ins, [a] * len(ins), [source] * len(ins)):
                print(line, flush=True)
    else:
        for p in ins:
            print(run(p, a, source), flush=True)


if __name__ == "__main__":
    main()
