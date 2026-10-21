"""Python model search path of a design, from its RTL source list (scripts/build.f).

Every IP whose sources build.f lists, and that has a model/ folder next to its src/, has that folder put
on sys.path: a design's models are those of the IPs it is built from. The IP directory of a source is its
path up to the first "src" or "include" component (../../ip/video/isp_gamma/src/isp_gamma.sv ->
../../ip/video/isp_gamma; src/video_processor.sv -> the design directory). A line `#model <ip dir>` adds an
IP whose model comes before its RTL (SystemVerilog tools skip lines starting with #). Two model folders
holding a module of the same name are an error (models are imported by module name).
Usage: with ip/shared/pymodel on sys.path, `import model_path; model_path.add(<design>/scripts/build.f)`.
"""
import os
import sys


def ip_dir(src, base):
    """IP directory of a build.f source path (relative to base), or None if it has no src / include part."""
    parts = os.path.normpath(src).split(os.sep)
    for k, p in enumerate(parts):
        if p in ("src", "include"):
            return os.path.normpath(os.path.join(base, *parts[:k])) if k else os.path.normpath(base)
    return None


def model_dirs(build_f):
    """model/ folders of the IPs build_f lists, in list order, each once."""
    base = os.path.dirname(os.path.dirname(os.path.abspath(build_f)))          # the design directory
    dirs = []
    with open(build_f, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln.startswith("#model "):
                ip = os.path.normpath(os.path.join(base, ln[len("#model "):].strip()))
            elif ln and not ln.startswith("#"):
                ip = ip_dir(ln, base)
            else:
                continue
            m = os.path.join(ip, "model") if ip else None
            if m and os.path.isdir(m) and m not in dirs:
                dirs.append(m)
    return dirs


def add(build_f):
    """Put the models of build_f's IPs on sys.path (after ip/shared/pymodel); returns their folders."""
    dirs = model_dirs(build_f)
    seen = {}
    for d in dirs:
        for f in os.listdir(d):
            if f.endswith(".py"):
                if f in seen:
                    raise RuntimeError(f"model module {f} in both {seen[f]} and {d}")
                seen[f] = d
    for d in dirs:
        if d not in sys.path:
            sys.path.append(d)
    return dirs
