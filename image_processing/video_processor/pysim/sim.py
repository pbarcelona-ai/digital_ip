"""video_processor system simulation in Python (the counterpart of scripts/run_sim.sh and
tb/video_processor_tb.sv): the firmware (sw/video_proc.py, compiled by pyc.py) runs on the py_core
instruction-set model with the py_soc peripherals, the board and the video system models. The models are
those of the IPs in scripts/build.f, each in its IP's model/ folder (ip/shared/pymodel/model_path.py).

Testbench protocol (as video_processor_tb.sv):
  - the camera streams live frames (the synthetic 32 x 24 RAW10 pattern) once the firmware has taken it
    out of reset (GPIO0[0]) and written "stream on" (CCI register 0x01 = 1);
  - section 7 (firmware stage 161): an image sequence of 8 frames, 4 colour (Bayer RGGB) then 4
    monochrome (format pin GPIO0[30]), GPIO0[29] high while it lasts;
  - section 8: for each input (GIF or video) the camera's control registers hold its frame size, name
    and detection options; once the firmware has set up sequence k (stage 170, seq_no = k) the frames are
    sent with GPIO0[29] high, each after the firmware committed the previous one's tracking result
    (global trk_frames), never sooner than the camera's frame gap;
  - the frames out of the overlay (HDMI) are captured and written as <name>_pysim.gif / .mp4, the
    report (UART 0, or the GPIO1 direct transcript) as <name>_pysim_transcript.txt.
Times are CPU clock cycles at 200 MHz (5 ns).
"""
import os
import re
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN = os.path.dirname(HERE)
ROOT = os.path.abspath(os.path.join(DESIGN, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DESIGN, "python-prototype"))
sys.path.insert(0, os.path.join(DESIGN, "tb", "scripts"))
sys.path.insert(0, os.path.join(ROOT, "ip", "shared", "pymodel"))
sys.path.insert(0, os.path.join(ROOT, "ip", "ai", "npu", "scripts"))           # npu_compiler

import model_path                             # noqa: E402

MODEL_DIRS = model_path.add(os.path.join(DESIGN, "scripts", "build.f"))      # each IP's model/, from build.f

from board import Board                       # noqa: E402
from event_sim import Sim                     # noqa: E402
from py_core_model import PyCore, Trap, load_hex   # noqa: E402
from py_soc_model import Soc                  # noqa: E402
import video_processor_model                  # noqa: E402

NS = 0.2                                      # CPU cycles per ns
LIVE_W, LIVE_H = 32, 24
CLASSES = ["pedestrian", "face", "automobile", "vehicle", "aircraft"]


def build_firmware(out_dir):
    """Compile sw/video_proc.py with pyc.py (as scripts/run_sim.sh): <out_dir>/video_proc.*"""
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "video_proc")
    cmd = [sys.executable, os.path.join(ROOT, "ip", "cpu", "py_core", "tools", "pyc.py"),
           "-I", os.path.join(DESIGN, "src"), "-I", os.path.join(ROOT, "ip", "cpu", "py_soc", "src"),
           "-I", os.path.join(ROOT, "ip", "video", "video_pipeline", "src"),
           "--code-aw", "15", "--str-slots", "1024", "--split-consts", "--core", "2",
           os.path.join(DESIGN, "sw", "video_proc.py"), "-o", out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"pyc.py failed:\n{r.stdout}{r.stderr}")
    return out


def live_raw():
    """The testbench's synthetic camera frame: 64 + ((37 x + 91 y + 13 x y) mod 900), RAW10."""
    y, x = np.mgrid[0:LIVE_H, 0:LIVE_W]
    return 64 + ((37 * x + 91 * y + 13 * x * y) % 900)


def to_raw(rgb, mono):
    """Camera RAW10 of an RGB frame: monochrome = BT.601 luma x 4; colour = RGGB mosaic x 4."""
    rgb = rgb.astype(np.int64)
    if mono:
        y = (77 * rgb[..., 0] + 150 * rgb[..., 1] + 29 * rgb[..., 2] + 128) >> 8
        return y << 2
    h, w = rgb.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    ch = np.where((yy & 1) == 0, np.where((xx & 1) == 0, 0, 1), np.where((xx & 1) == 0, 1, 2))
    return np.take_along_axis(rgb, ch[..., None], 2)[..., 0] << 2


def image_sequence():
    """Section 7: 4 colour and 4 monochrome 32 x 24 test images."""
    out = []
    y, x = np.mgrid[0:LIVE_H, 0:LIVE_W]
    for n in range(8):
        r = (x * 8 + n * 30) % 256
        g = (y * 10 + n * 20) % 256
        b = ((x + y) * 5 + n * 40) % 256
        out.append((np.stack([r, g, b], -1).astype(np.uint8), n >= 4))
    return out


class Input:
    """One tracking input: frames (RGB, fitted inside fit: 320 x 240 by default as the SV testbench, larger
    for the NPU), frame delays (ms), name, options."""

    def __init__(self, path, fps=10.0, start=0.0, vframes=100, first=0, nframes=0, bw=False, fit=(320, 240)):
        import detect_proto
        frames, delays = detect_proto.load(path, fps, start, vframes, fit)
        frames, delays = frames[first:], delays[first:]
        if nframes:
            frames, delays = frames[:nframes], delays[:nframes]
        self.frames, self.delays = frames, delays
        self.name = os.path.splitext(os.path.basename(path))[0] + (f"_from{first}" if first else "")
        self.h, self.w = frames[0].shape[:2]
        sat = max(int(np.abs(f.astype(int) - f.astype(int).mean(-1, keepdims=True)).max()) for f in frames[:5])
        self.mono = bw or sat < 8                      # a black-and-white GIF goes out monochrome


class System:
    def __init__(self, fw, quick=True, direct=False, transcript=None, echo=False, npu_prog=None):
        self.sim = Sim(200_000_000)
        self.board = Board(quick=quick, direct=direct, transcript=transcript)
        if echo:
            self.board.echo = lambda line: print("UART0| " + line, flush=True)
        with open(fw + ".flash.bin", "rb") as fh:
            self.soc = Soc(self.sim, fh.read(), self.board)
        self.vsys = video_processor_model.VideoSystem(self.sim, self.soc)
        self.soc.ext = self.vsys
        self.soc.ddr = self.vsys.ddr                  # the CPU's DDR window
        if npu_prog is not None:                      # the NPU program preloaded in DDR (as a boot loader would)
            import npu_compiler
            npu_compiler.load_into(self.vsys.ddr, npu_prog)
        for i, f in enumerate(self.vsys.irq_lines()):
            self.soc.set_ext_irq(i, f)
        self.soc.core_reset_cb = self._core_reset
        self.core = PyCore.v2(load_hex(fw + ".code.hex"), load_hex(fw + ".const.hex"), self.soc)
        with open(fw + "_syms.svh", encoding="utf-8") as fh:
            self.syms = {m.group(1): int(m.group(2)) for m in
                         re.finditer(r"localparam int G_(\w+) = (\d+);", fh.read())}
        self.released = False
        self.cam_busy = False
        self.seq = None                               # list of (rgb, mono) being sent, or None (live)
        self.seq_k = 0
        self.seq_kind = None
        self.seq_t0 = 0
        self.capturing = False                        # output frames of a tracking sequence are kept
        self.captured = []
        self.tracker_in = []
        self.vs_busy_until = 0
        self.trk_f0 = 0
        self.on_frame = None
        self.live = True                              # live raw frames until the video checks are done

    def g(self, name):
        """Firmware global (0 until the program has assigned it)."""
        v = self.core.global_value(self.syms[name])
        return 0 if v is None else v

    def _core_reset(self, release):
        if release and not self.released:
            self.released = True
            self.sim.after(1000, self._camera)

    # ---- camera
    def _frame_cycles(self, w, h):
        line = max(w * 11.5, 2.0 * w + 200) * NS          # a line lasts 11.5 ns per pixel or more
        gap = self.board.camera.get16(0x20) * NS
        return int(h * line + gap)

    def _camera(self):
        """Next camera frame: live, or the next frame of a sequence once the firmware is ready for it."""
        cam = self.board.camera
        if not (cam.streaming() and self.board.cam_reset_n):
            self.sim.after(20_000, self._camera)
            return
        if self.seq is not None:
            if self.seq_k >= len(self.seq):
                self._end_sequence()
                self.sim.after(20_000, self._camera)
                return
            if self.seq_kind == "track" and self.g("trk_frames") - self.trk_f0 < self.seq_k:
                self.sim.after(2_000, self._camera)       # the previous frame's result is not committed yet
                return
            if self.sim.now < self.vs_busy_until:
                self.sim.after(self.vs_busy_until - self.sim.now + 10, self._camera)
                return
            rgb, mono = self.seq[self.seq_k]
            if self.board.mono != mono:
                self.board.mono = mono                    # the format pin changes before the frame
                self.soc.gpio0.sample()
                self.sim.after(40_000, self._camera)      # the firmware reprograms the ISP
                return
            self.seq_k += 1
            raw = to_raw(rgb, mono)
        elif self.live:
            raw = live_raw()
        else:                                         # img_mode: live frames stopped, sequence pending
            self.sim.after(20_000, self._camera)
            return
        h, w = raw.shape
        t = self._frame_cycles(w, h)
        self.sim.after(t, lambda: self._frame_end(raw, w, h))

    def _end_sequence(self):
        self.seq = None
        self.board.seq_active = False
        self.soc.gpio0.sample()

    def _frame_end(self, raw, w, h):
        """The frame's last line left the camera: through the pipeline, with its events."""
        v = self.vsys
        v.pipe.csi_frames += 1
        line = int(max(w * 11.5, 2.0 * w + 200) * NS)
        insert = bool(v.pipe.r.get("CTRL") & 0x80)
        # the pipeline computes the whole frame now; events follow with the latencies
        out, tin, feats = v.process(raw, None)                  # CFA from the pipeline CTRL
        v.pipe.stats_irq = False
        self.sim.after(10 * line, lambda: self._ev_first())
        if insert:
            vs_time = int(w * h * 2 + 40 * w)              # vision_system: capture, then generate at 1 px / clk
            self.vs_busy_until = self.sim.now + 10 * line + vs_time
            self.sim.after(10 * line + 4, lambda: self._ev(2))
            self.sim.after(10 * line + vs_time, lambda: self._vs_out())
            npu_t = v.npu.cycles                           # the NPU's run (0 without one) before the results
            self.sim.after(10 * line + vs_time + 3 * w * 2 + npu_t, lambda: self._track_done(out, tin, feats))
            self.sim.after(10 * line + vs_time + 4 * w * 2 + npu_t, lambda: self._ev(1))
        else:
            self.sim.after(12 * line, lambda: self._track_done(out, tin, feats))
            self.sim.after(13 * line, lambda: self._ev(1))
        self.sim.after(max(line, 2000), self._camera)

    def _ev_first(self):
        self._ev(0)
        self.vsys.pipe.stats_irq = True                         # isp_stats frame done (edge source)
        self.soc.update_irq()
        self.sim.after(40, self._stats_low)

    def _stats_low(self):
        self.vsys.pipe.stats_irq = False
        self.soc.update_irq()

    def _vs_out(self):
        self.vsys.vision.done = True
        self._ev(3)

    def _track_done(self, out, tin, feats):
        self._ev(4)
        if self.seq_kind == "track" and self.capturing:
            self.captured.append(out)
            self.tracker_in.append(tin)
            if self.on_frame:
                self.on_frame(len(self.captured) - 1, out)

    def _ev(self, ch):
        self.vsys.fc.marker(ch)

    # ---- the testbench's sequences
    def start_sequence(self, frames, kind):
        self.seq = list(frames)
        self.seq_k = 0
        self.seq_kind = kind
        self.capturing = kind == "track"
        self.board.seq_active = True
        self.soc.gpio0.sample()

    def run(self, inputs, styles, det_mask, max_targets, log=print, max_seconds=None):
        """The whole run: boot, sections 1-7, then each input's tracking sequence (section 8), summary."""
        cam = self.board.camera
        first = inputs[0]
        cam.load(first.w, first.h, first.name, det_mask, styles, max_targets, len(inputs), 0)
        t_wall = time.time()
        stage = lambda: self.g("stage")
        self.capturing = False
        results = []
        # boot to the frame-count report (stage 160): the video checks are done, the camera stops its
        # live frames (testbench img_mode) so the firmware sees the pipeline empty, then the image sequence
        self._run_until(lambda: stage() >= 160 or self.core.done, max_seconds, t_wall)
        self.live = False
        self._run_until(lambda: stage() in (161, 169, 170, 200) or self.core.done, max_seconds, t_wall)
        if stage() == 161:
            self.start_sequence(image_sequence(), "images")
            self._run_until(lambda: stage() not in (160, 161) or self.core.done, max_seconds, t_wall)
        for k, inp in enumerate(inputs):
            cam.load(inp.w, inp.h, inp.name, det_mask, styles, max_targets, len(inputs), k + 1)
            self._run_until(lambda: (stage() == 170 and self.g("seq_no") == k + 1) or self.core.done,
                            max_seconds, t_wall)
            if self.core.done or stage() != 170:
                break
            self.trk_f0 = self.g("trk_frames")
            self.captured, self.tracker_in = [], []
            log(f"  [{inp.name}] {len(inp.frames)} frames of {inp.w} x {inp.h}"
                f" ({'monochrome' if inp.mono else 'colour'})")
            self.start_sequence([(f, inp.mono) for f in inp.frames], "track")
            self._run_until(lambda: stage() == 180 or self.core.done, max_seconds, t_wall)
            self._run_until(lambda: stage() != 180 or self.core.done, max_seconds, t_wall)
            results.append((inp, list(self.captured), list(self.tracker_in)))
        self._run_until(lambda: self.core.done or stage() == 200, max_seconds, t_wall)
        return results

    def _run_until(self, cond, max_seconds, t_wall):
        try:
            while not cond():
                self.core.run(max_instructions=200_000, until=cond)
                if max_seconds and time.time() - t_wall > max_seconds:
                    raise TimeoutError(f"simulation stopped after {max_seconds} s (stage {self.g('stage')})")
        except Trap as e:
            raise RuntimeError(f"py_core {e}") from None
