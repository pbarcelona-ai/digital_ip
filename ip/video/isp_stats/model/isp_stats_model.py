"""isp_stats model (Python model of ip/video/isp_stats/src/isp_stats.sv), frame level: the sum of each
component, the number of pixels and the number of pixels with any component >= sat_thr (clipping) of a
frame; the totals describe the last complete frame. The RTL reports a frame (frame_done_o, the totals, FRAMES + 1)
in the clock after the next frame's first pixel, or after flush_i while a frame is open; a flush with no frame open
reports nothing. Sums are 40 bits, counts 32 bits (CW-bit components, {B, G, R} with R in the LSBs)."""
import numpy as np


def stats(rgb, sat_thr):
    """dict(r, g, b, pix, clip) of an h x w x 3 frame."""
    r = rgb.astype(np.int64)
    return dict(r=int(r[..., 0].sum()), g=int(r[..., 1].sum()), b=int(r[..., 2].sum()), pix=r.shape[0] * r.shape[1],
                clip=int((r.max(-1) >= sat_thr).sum()))
