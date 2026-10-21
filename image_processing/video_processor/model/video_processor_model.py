"""video_processor video system model (Python model of src/video_processor.sv without py_soc): the blocks
behind py_soc's external window at frame level, each from its own IP model, and the frame data path.

Window (video_processor_map_pkg.sv, offsets from 0x1_0000):
  0x0000 video_pipeline (its scaler_bilinear at 0x4000)   0x8000 vision_system   0x8200 blur_sharpen (analysis)
  0x8400 frame_counter   0x8500 feature_detect   0x8600 blur_sharpen (display)   0x8C00 symbol_overlay
  0x9000 + 0x200 c object_tracker c   0xA000 npu (new in the model)

Data path of a camera frame (the insert loop of video_processor.sv):
  camera RAW10 (Bayer RGGB for colour, the luma for monochrome) -> csi2_rx / csi2_raw_unpack -> ISP
  (video_pipeline) -> vs_stream_adapter -> vision_system (lens correction) -> npu frame writer -> blur_sharpen
  (display, 0x8600) -> symbol_overlay -> back into video_pipeline -> scaler (BYPASS[7]) -> axis_to_video ->
  HDMI / LVDS; the analysis path branches after vision_system: blur_sharpen (analysis, 0x8200) ->
  feature_detect, object_tracker x NTRK (they drive the overlay through the firmware).
Timing is modelled at frame level by the system simulation (pysim/sim.py): a frame enters at the camera's
frame end and its events (frame_counter channels 0-4) are scheduled with the pipeline latencies, in the same
order as in the RTL.
"""
from blur_sharpen_model import BlurSharpen
from feature_detect_model import FeatureDetect
from frame_counter_model import FrameCounter
from npu_model import Ddr, NpuTop
from object_tracker_model import ObjectTracker
from scaler_bilinear_model import Scaler
from symbol_overlay_model import NOBJ, NTXT, SymbolOverlay
from video_pipeline_model import VideoPipeline
from vision_system_model import VisionSystem

DDR_BYTES = 256 << 20          # DDR shared by the NPU (frame buffer, program, tensors, detections) and the CPU
NPU_OFF = 0xA000               # NPU registers in the video window (0x1_A000; new in the model)
NTRK = 5                       # object_tracker detectors: pedestrian, face, automobile, vehicle, aircraft
NFC = 5                        # frame_counter channels


class VideoSystem:
    """The video system: every block of the window, its bus decoder, interrupt lines and process(frame)."""

    def __init__(self, sim, soc):
        self.sim, self.soc = sim, soc
        self.pipe = VideoPipeline()
        self.scaler = Scaler()
        self.vision = VisionSystem()
        self.flt = BlurSharpen()                     # analysis path
        self.fltd = BlurSharpen()                    # display path
        self.fc = FrameCounter(sim, soc.update_irq, NFC)
        self.feat = FeatureDetect()
        self.trk = [ObjectTracker() for _ in range(NTRK)]
        self.ovl = SymbolOverlay(NOBJ, NTXT)
        self.ddr = Ddr(DDR_BYTES)
        self.npu = NpuTop(self.ddr)

    def irq_lines(self):
        """External interrupt sources 12-15: isp_stats frame done (edge), frame_counter channels 0 / 1
        (level: STATUS & IRQ_EN), and on the spare source 15 frame_counter channels 2-4 together (new in
        the model: video_processor.sv leaves 15 to ext_irq_i)."""
        fc = self.fc
        return [lambda: self.pipe.stats_irq, lambda: bool(fc.irq(0)), lambda: bool(fc.irq(1)),
                lambda: bool(fc.irq(2) or fc.irq(3) or fc.irq(4))]

    # -- bus window
    def _decode(self, off):
        if off < 0x8000:
            if off >= 0x4000:
                return self.scaler, off - 0x4000
            return self.pipe.r, off
        if 0x8000 <= off < 0x8100:
            return self.vision.r, off - 0x8000
        if 0x8200 <= off < 0x8400:
            return self.flt.r, off - 0x8200
        if 0x8400 <= off < 0x8500:
            return self.fc.r, off - 0x8400
        if 0x8500 <= off < 0x8600:
            return self.feat.r, off - 0x8500
        if 0x8600 <= off < 0x8800:
            return self.fltd.r, off - 0x8600
        if 0x8C00 <= off < 0x9000:
            return self.ovl.r, off - 0x8C00
        if 0x9000 <= off < 0x9000 + 0x200 * NTRK:
            return self.trk[(off - 0x9000) >> 9].r, (off - 0x9000) & 0x1FF
        if NPU_OFF <= off < NPU_OFF + 0x100:
            return self.npu.r, off - NPU_OFF
        return None, 0

    def read(self, off):
        t, o = self._decode(off)
        if t is None:
            return 0, 3
        return t.read(o)

    def write(self, off, d):
        t, o = self._decode(off)
        if t is None:
            return 3
        return t.write(o, d)

    # -- frames
    def process(self, raw, cfa=None):
        """One camera frame through the pipeline (cfa None: the pipeline's CTRL[5:4], as the RTL). Returns (output
        frame, tracker input frame, features).

        Two paths after vision_system, each with its own blur_sharpen (new in the model): the display path
        (blur_sharpen at 0x8600 -> symbol_overlay) sets the picture quality, the analysis path (blur_sharpen
        at 0x8200 -> feature_detect, object_trackers) the filtering that suits detection."""
        rgb = self.pipe.run(raw, cfa)
        vis = self.vision.run(rgb)
        self.npu.frame(vis)                                            # frame writer (and AUTO run)
        tin = self.flt.run(vis)                                        # analysis path
        edge, mot = self.feat.step(tin)
        for t in self.trk:
            t.measure(tin, edge, mot)
        disp = self.fltd.run(vis)                                      # display path
        self.ovl.frame_start()
        out = self.ovl.draw(disp)
        return out, tin, (edge, mot)
