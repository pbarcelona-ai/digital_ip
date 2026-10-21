"""video_pipeline model (Python model of ip/video/video_pipeline/src/video_pipeline.sv), frame level: its
register block (video_pipeline_regs.json) and the ISP chain on a camera RAW10 frame, each stage from its
own IP model, skipped when its BYPASS bit is set:
  [0] isp_blc_wb black level  [1] isp_blc_wb white balance  [2] isp_dpc  [3] isp_demosaic (bypassed: the
  RAW value in all three components)  [4] isp_ccm  [5] isp_gamma (bypassed: >> 2)  [6] isp_csc (CTRL[6]
  BT.709, else BT.601; bypassed: RGB)
with CTRL[5:4] the CFA pattern. isp_stats taps the linear 10-bit RGB after the CCM (STAT_THR[9:0] the clipping
level); a frame's totals are reported (STAT_*, STAT_FRAMES + 1) when the next frame's first pixel reaches the tap
(the RTL never flushes). DPC_CORR counts every corrected pixel, CSI_FRAMES the CSI-2 frame starts (the host's
count), the gamma table is written through GAMMA_ADDR / GAMMA_DATA (the address increments). BUILD_CFG 0x7F,
STATUS 1 (the display locked: the output side - video timing, genlock, HDMI / LVDS / DSI / CSI-2 TX - is not
modelled); BUILD_CFG is the build's interface set (0x7F in video_processor)."""
import numpy as np

from isp_blc_wb_model import blc, wb
from isp_ccm_model import ccm
from isp_csc_model import csc_frame
from isp_demosaic_model import demosaic
from isp_dpc_model import dpc_frame
from isp_gamma_model import gamma, linear_curve
from isp_stats_model import stats
from pixel import bayer_colour, signed
from regs import RegMap, ip_regs


class VideoPipeline:
    """video_pipeline: registers, gamma table, isp_stats totals, CSI-2 frame count, the ISP chain."""

    def __init__(self, build_cfg=0x7F):
        self.r = RegMap(ip_regs(__file__, "video_pipeline"))
        self.build_cfg = build_cfg                                      # BUILD_CFG: the interfaces built
        self.gamma = linear_curve()                                     # power-up linear curve
        self.csi_frames = 0
        self.stat = dict(r=0, g=0, b=0, pix=0, clip=0, frames=0)
        self.stat_open = None                                           # totals of the frame not yet reported
        self.dpc_corr = 0
        self.stats_irq = False                                          # isp_stats frame done (the system pulses it)
        self.r.sts = self._sts
        self.r.on_write = self._w

    def _sts(self, n, i):
        return {"STATUS": 1, "STAT_SUM_R": self.stat["r"] & 0xFFFFFFFF, "STAT_SUM_G": self.stat["g"] & 0xFFFFFFFF,
                "STAT_SUM_B": self.stat["b"] & 0xFFFFFFFF, "STAT_PIX": self.stat["pix"], "STAT_CLIP": self.stat["clip"],
                "STAT_FRAMES": self.stat["frames"], "CSI_FRAMES": self.csi_frames, "DPC_CORR": self.dpc_corr & 0xFFFFFFFF,
                "BUILD_CFG": self.build_cfg}.get(n, 0)

    def _w(self, n, i, d):
        if n == "GAMMA_DATA":
            a = self.r.get("GAMMA_ADDR") & 1023
            self.gamma[a] = d & 0xFF
            self.r.set("GAMMA_ADDR", (a + 1) & 1023)

    def isp(self, raw, cfa=None):
        """The ISP chain on a RAW10 frame (h x w ints): h x w x 3 uint8 (Cr, Y, Cb, or RGB with the CSC bypassed);
        the linear RGB after the CCM is kept for isp_stats. cfa None: CTRL[5:4]."""
        r = self.r
        byp = r.get("BYPASS")
        ctrl = r.get("CTRL")
        cfa = (ctrl >> 4) & 3 if cfa is None else cfa
        raw = raw.astype(np.int64)
        h, w = raw.shape
        col = bayer_colour(h, w, cfa)
        if not byp & 1:
            raw = blc(raw, col, [r.get("BLC_R"), r.get("BLC_GR"), r.get("BLC_GB"), r.get("BLC_B")])
        if not byp & 2:
            raw = wb(raw, col, [r.get("WB_R"), r.get("WB_G"), r.get("WB_G"), r.get("WB_B")])
        raw, corrected = dpc_frame(raw, r.get("DPC_THR") & 1023, bool(byp & 4))
        self.dpc_corr += corrected
        if not byp & 8:
            rgb = demosaic(raw, col)
        else:
            rgb = np.stack([raw, raw, raw], -1)
        if not byp & 16:
            coef = [[signed(r.get(f"CCM_C{i}{j}"), 16) for j in range(3)] for i in range(3)]
            rgb = ccm(rgb, coef, [signed(r.get(f"CCM_OFF_{c}"), 16) for c in "RGB"])
        self.linear = rgb
        if not byp & 32:
            rgb = gamma(rgb, self.gamma)
        else:
            rgb = rgb >> 2
        rgb = csc_frame(np.clip(rgb, 0, 255), bool(ctrl & 64), bool(byp & 64))
        return rgb.astype(np.uint8)

    def run(self, raw, cfa=None):
        """A camera frame through the ISP: the ISP output. Its first pixel reports the previous frame's isp_stats
        totals; this frame's are reported by the next one."""
        if self.stat_open is not None:
            self.stat = dict(self.stat_open, frames=self.stat["frames"] + 1)
        rgb = self.isp(raw, cfa)
        self.stat_open = stats(self.linear, self.r.get("STAT_THR") & 1023)
        return rgb
