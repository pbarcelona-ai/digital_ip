#!/usr/bin/env python3
# ***************
# Filename: mp4_io.py
# Author: FPGA Cores 4 U
# Description: MP4 reader / writer of the video_processor testbench (PyAV:
#   the FFmpeg libraries, `pip install av`). The SystemVerilog testbench reads
#   and writes animated GIFs (video_tb_lib/gif_io.sv); this script turns a
#   camera video (MP4, MOV, MKV, WebM: H.264, HEVC, ...) into the GIF the
#   testbench sends through the camera, and the tracked GIF the testbench
#   writes back into an MP4:
#     to-gif   decode the video from a start time at a frame rate (frames
#              picked at start + k / fps, nearest decoded frame), scale each
#              to fit the tracking frame (320 x 240 by default, aspect kept,
#              width a multiple of 4, height even; area filter) and write a looping GIF (a 256-colour palette of
#              its own per frame, no dithering; delay 1 / fps)
#     to-mp4   encode an animated GIF (the tracked output) as H.264 MP4
#              (yuv420p, CRF 18), every pixel scaled up SCALE times (nearest:
#              the 1-pixel boxes stay sharp), the GIF's frame delays kept
#     info     size, frame rate, length and codec of a video
#   scripts/run_sim.sh calls it for --gif=<video> (see there).
# Date: 2026-10-15
# ***************
# Usage: mp4_io.py to-gif <video> <out.gif> [--fps F] [--start S] [--frames N] [--fit WxH]
#        mp4_io.py to-mp4 <in.gif> <out.mp4> [--scale K] [--crf C]
#        mp4_io.py info <video>
import argparse
import os
import sys
from fractions import Fraction

from PIL import Image, ImageSequence

try:
    import av
except ImportError:
    sys.exit("mp4_io.py: needs PyAV (the FFmpeg libraries for Python): python3 -m pip install av")

VIDEO_EXT = ('.mp4', '.m4v', '.mov', '.mkv', '.webm', '.avi')


def info(path):
    with av.open(path) as c:
        s = c.streams.video[0]
        if c.duration:
            dur = float(c.duration / av.time_base)
        elif s.duration and s.time_base:
            dur = float(s.duration * s.time_base)
        else:
            dur = 0.0                                      # unknown (a stream without a duration)
        return dict(width=s.width, height=s.height, fps=float(s.average_rate or s.guessed_rate),
                    seconds=dur, codec=s.codec_context.name)


def fit(w, h, mw, mh):
    """w x h scaled to fit mw x mh, aspect kept (never up); width a multiple of 4, height even (the
    camera's Bayer pattern and the 4-pixel feature cells)."""
    k = min(mw / w, mh / h, 1.0)
    return max(4, min(mw, round(w * k / 4) * 4)), max(2, min(mh, round(h * k / 2) * 2))


def read_video(path, fps=10.0, start=0.0, frames=0, fit_w=320, fit_h=240):
    """Frames (PIL RGB) of the video at start + k / fps, k = 0 .. frames - 1 (0: to the end), scaled
    to fit fit_w x fit_h. Times count from the stream's first frame: a stream whose first timestamp is
    after `start` returns frames from its first one. Every sampled frame is decoded (FFmpeg cannot skip
    the frames in between cheaply: 3-16 s for the 4K clips). The file is opened by FFmpeg: treat videos
    from elsewhere as untrusted input and keep PyAV current."""
    if fps <= 0:
        raise ValueError('fps must be above 0, not %g' % fps)
    out = []
    with av.open(path) as c:
        s = c.streams.video[0]
        s.thread_type = 'AUTO'
        if start > 0:
            c.seek(int(start / s.time_base), stream=s, backward=True)
        half = 0.5 / float(s.average_rate or 30)
        w = h = None
        k = 0
        for f in c.decode(s):
            if f.time is None:
                continue
            if w is None:
                w, h = fit(f.width, f.height, fit_w, fit_h)
            want = start + k / fps
            if f.time + half < want:                       # before the next sample time
                continue
            img = f.to_image(width=w, height=h, interpolation='AREA')
            while f.time + half >= want:                   # (a slow source repeats frames)
                out.append(img)
                k += 1
                if frames and k >= frames:
                    return out
                want = start + k / fps
    return out


def gif_palette(frame):
    """A frame as the GIF holds it: a palette of its own (median cut, 256 colours, no dithering)."""
    return frame.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)


def gif_colours(frame):
    """The RGB colours of a frame after the GIF round trip (what the testbench sends)."""
    return gif_palette(frame).convert('RGB')


# the overlay's symbol and text colours (white, red, green, yellow, blue, cyan, magenta, black)
OVERLAY_COLOURS = ((255, 255, 255), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (0, 255, 255),
                   (255, 0, 255), (0, 0, 0))


def gif_palette_keep(frame, keep, tol=0):
    """A frame with a palette of its own: 256 - len(keep) median-cut colours plus the colours in keep
    exactly; a pixel within tol (every channel) of a keep colour takes that colour. Thin overlay symbols
    are too few pixels for median cut to give their colour an entry of its own (a green triangle on a sky
    came out grey)."""
    import numpy as np
    n = 256 - len(keep)
    q = frame.quantize(n, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    idx = np.array(q, np.uint8)
    pal = (q.getpalette() or [])[:3 * n]
    pal += [0] * (3 * n - len(pal))
    rgb = np.asarray(frame.convert('RGB'), np.int16)
    for k, c in enumerate(keep):
        idx[(np.abs(rgb - np.array(c, np.int16)) <= tol).all(-1)] = n + k
        pal += list(c)
    out = Image.fromarray(idx, 'P')
    out.putpalette(pal)
    return out


def write_gif(frames, path, fps, keep=(), tol=0):
    """Looping GIF, a palette of its own per frame (median cut, no dithering), delay 1 / fps; keep: colours
    given palette entries of their own (gif_palette_keep; e.g. OVERLAY_COLOURS for the tracked output)."""
    pal = [gif_palette_keep(f, keep, tol) if keep else gif_palette(f) for f in frames]
    tmp = path + '.tmp'
    try:
        pal[0].save(tmp, format='GIF', save_all=True, append_images=pal[1:], loop=0,
                    duration=max(20, round(1000 / fps / 10) * 10), disposal=1, optimize=False)
        os.replace(tmp, path)                              # whole or not at all (parallel runs)
    except BaseException:
        if os.path.exists(tmp):                            # no partial file left behind
            os.remove(tmp)
        raise


def gif_to_mp4(src, dst, scale=2, crf=18):
    """The GIF's frames as H.264 MP4, scaled up `scale` times (nearest), its frame delays kept."""
    im = Image.open(src)
    frames, delays = [], []
    for f in ImageSequence.Iterator(im):
        frames.append(f.convert('RGB'))
        delays.append(f.info.get('duration', 100) or 100)
    w, h = frames[0].size
    frames = [f.resize((w * scale, h * scale), Image.NEAREST) for f in frames]
    return write_mp4(frames, delays, dst, crf)


def write_mp4(frames, delays, dst, crf=18):
    """PIL RGB frames, each shown delays[k] ms, as H.264 MP4 (yuv420p; odd sizes padded to even). An MP4
    frame lasts until the next one starts, so the last frame is written once more at the end time: its
    delay (a held last frame) is kept."""
    if not frames or len(frames) != len(delays):
        raise ValueError('write_mp4: %d frames, %d delays' % (len(frames), len(delays)))
    w, h = frames[0].size
    ow, oh = w + w % 2, h + h % 2                          # H.264 4:2:0: even size
    tb = Fraction(1, 1000)                                 # time in ms
    tmp = dst + '.tmp.mp4'
    try:
        _encode(tmp, frames, delays, ow, oh, tb, crf)
        os.replace(tmp, dst)
    except BaseException:
        if os.path.exists(tmp):                            # no partial file left behind
            os.remove(tmp)
        raise
    return len(frames), ow, oh


def _encode(tmp, frames, delays, ow, oh, tb, crf):
    """The H.264 encoding of write_mp4 into tmp."""
    with av.open(tmp, 'w') as c:
        s = c.add_stream('libx264', rate=Fraction(1000, max(1, round(sum(delays) / len(delays)))))
        s.width, s.height, s.pix_fmt = ow, oh, 'yuv420p'
        s.time_base = tb
        s.codec_context.time_base = tb
        s.options = {'crf': str(crf), 'preset': 'medium'}
        t = 0
        for f, d in list(zip(frames, delays)) + [(frames[-1], 0)]:   # (the last again: its delay kept)
            big = Image.new('RGB', (ow, oh))
            big.paste(f)
            vf = av.VideoFrame.from_image(big)
            vf.pts, vf.time_base = t, tb
            for p in s.encode(vf):
                c.mux(p)
            t += max(1, d)
        for p in s.encode():
            c.mux(p)


def main():
    ap = argparse.ArgumentParser(description='MP4 reader / writer of the video_processor testbench')
    sub = ap.add_subparsers(dest='cmd', required=True)
    g = sub.add_parser('to-gif', help='video -> GIF for the testbench')
    g.add_argument('video')
    g.add_argument('gif')
    g.add_argument('--fps', type=float, default=10.0, help='frames per second taken (default 10)')
    g.add_argument('--start', type=float, default=0.0, help='start time in seconds (default 0)')
    g.add_argument('--frames', type=int, default=0, help='frames taken (default 0: to the end)')
    g.add_argument('--fit', default='320x240', help='largest frame size (default 320x240)')
    m = sub.add_parser('to-mp4', help='GIF (tracked output) -> MP4')
    m.add_argument('gif')
    m.add_argument('mp4')
    m.add_argument('--scale', type=int, default=2, help='pixel scale (default 2)')
    m.add_argument('--crf', type=int, default=18, help='x264 quality (default 18)')
    i = sub.add_parser('info', help='size, rate, length, codec')
    i.add_argument('video')
    a = ap.parse_args()
    if a.cmd == 'to-gif':
        fw, fh = (int(v) for v in a.fit.lower().split('x'))
        fr = read_video(a.video, a.fps, a.start, a.frames, fw, fh)
        if not fr:
            sys.exit('mp4_io.py: no frames in %s from %.2f s' % (a.video, a.start))
        write_gif(fr, a.gif, a.fps)
        v = info(a.video)
        print('mp4_io: %s (%d x %d, %.2f fps, %.1f s, %s) -> %s: %d frames of %d x %d at %g fps from %.2f s'
              % (os.path.basename(a.video), v['width'], v['height'], v['fps'], v['seconds'], v['codec'], a.gif,
                 len(fr), fr[0].size[0], fr[0].size[1], a.fps, a.start))
    elif a.cmd == 'to-mp4':
        n, w, h = gif_to_mp4(a.gif, a.mp4, a.scale, a.crf)
        print('mp4_io: %s -> %s: %d frames of %d x %d (H.264)' % (a.gif, a.mp4, n, w, h))
    else:
        v = info(a.video)
        print('%s: %d x %d, %.3f fps, %.2f s, %s' % (a.video, v['width'], v['height'], v['fps'], v['seconds'],
                                                     v['codec']))


if __name__ == '__main__':
    main()
