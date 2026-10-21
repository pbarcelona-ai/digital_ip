"""Shared cocotb helpers of the library's model comparisons (each IP's tb/python).

  AxilMaster   AXI4-Lite master on a wrapper's flattened ports (<prefix>_awaddr, ...): write() / read()
               return the response code, the transfer takes the slave's own time (valid held until ready).
  simulator_config()  (runner name, build arguments) from PYTHON_SIM (verilator, the default, or icarus);
               Verilator gets --public-flat-rw (tests read internal state) and -std=c++17.
  run_cases()  builds and runs one test module for each parameter set (optional plusargs / environment);
               raises SystemExit on a failure (an Icarus exit crash after every test passed is reported as such,
               not as a failure).
  build_f_sources()  an IP's RTL sources from its scripts/build.f.
  model_path() puts ip/shared/pymodel and the given model folders on sys.path (the models import RegMap).
  run_frames() streams frames of beats through a one-in / one-out AXI4-Stream block (s_* / m_* ports) with
               random input gaps and output back-pressure; returns the output beats.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from cocotb.triggers import FallingEdge, RisingEdge, Timer

IP_ROOT = Path(__file__).resolve().parents[3]                    # ip/


def build_f_sources(ip_dir):
    """The RTL sources of an IP, from its scripts/build.f (paths relative to the IP directory)."""
    ip_dir = Path(ip_dir)
    with open(ip_dir / "scripts" / "build.f", encoding="utf-8") as fh:
        return [(ip_dir / ln.strip()).resolve() for ln in fh if ln.strip() and not ln.strip().startswith("#")]


def model_path(*dirs):
    """sys.path for the models: ip/shared/pymodel and dirs (model folders)."""
    for d in (IP_ROOT / "shared" / "pymodel", *dirs):
        if str(d) not in sys.path:
            sys.path.insert(0, str(d))


class AxilMaster:
    """AXI4-Lite master on the wrapper ports <prefix>_*, clocked by clk; one transfer at a time. Signals are
    driven after a rising edge and handshakes sampled at the rising edge (the values the slave sees)."""

    def __init__(self, dut, clk, prefix="axi", timeout=1000):
        self.clk, self.timeout = clk, timeout
        self.s = {n: getattr(dut, f"{prefix}_{n}") for n in (
            "awaddr", "awvalid", "awready", "wdata", "wstrb", "wvalid", "wready", "bresp", "bvalid", "bready",
            "araddr", "arvalid", "arready", "rdata", "rresp", "rvalid", "rready")}
        for n in ("awvalid", "wvalid", "bready", "arvalid", "rready", "awaddr", "wdata", "araddr"):
            self.s[n].value = 0
        self.s["wstrb"].value = 0xF

    def _hs(self, valid, ready):
        return self.s[valid].value == 1 and self.s[ready].value == 1

    async def write(self, addr, data, strb=0xF):
        """One write: the response code (0 OKAY, 2 SLVERR, 3 DECERR)."""
        s = self.s
        await RisingEdge(self.clk)
        s["awaddr"].value, s["wdata"].value, s["wstrb"].value = addr, data & 0xFFFFFFFF, strb
        s["awvalid"].value = s["wvalid"].value = 1
        aw = w = False
        for _ in range(self.timeout):                            # AW and W, in either order
            await RisingEdge(self.clk)
            if not aw and self._hs("awvalid", "awready"):
                aw = True
                s["awvalid"].value = 0
            if not w and self._hs("wvalid", "wready"):
                w = True
                s["wvalid"].value = 0
            if aw and w:
                break
        else:
            raise TimeoutError("AXI4-Lite write: AW / W not accepted")
        s["bready"].value = 1
        for _ in range(self.timeout):
            await RisingEdge(self.clk)
            if self._hs("bvalid", "bready"):
                resp = int(s["bresp"].value)
                s["bready"].value = 0
                return resp
        raise TimeoutError("AXI4-Lite write: no B response")

    async def read(self, addr):
        """One read: (data, response code)."""
        s = self.s
        await RisingEdge(self.clk)
        s["araddr"].value = addr
        s["arvalid"].value = 1
        for _ in range(self.timeout):
            await RisingEdge(self.clk)
            if self._hs("arvalid", "arready"):
                s["arvalid"].value = 0
                break
        else:
            raise TimeoutError("AXI4-Lite read: AR not accepted")
        s["rready"].value = 1
        for _ in range(self.timeout):
            await RisingEdge(self.clk)
            if self._hs("rvalid", "rready"):
                data, resp = int(s["rdata"].value), int(s["rresp"].value)
                s["rready"].value = 0
                return data, resp
        raise TimeoutError("AXI4-Lite read: no R response")


def simulator_config():
    """(runner name, build arguments) for PYTHON_SIM."""
    name = os.environ.get("PYTHON_SIM", "verilator").lower()
    if name in {"icarus", "iverilog"}:
        return "icarus", []
    if name == "verilator":
        if sys.platform == "darwin":                              # the Python library for the embedded cocotb
            library_dir = Path(sys.executable).resolve().parent.parent / "lib"
            if (library_dir / f"libpython{sys.version_info.major}.{sys.version_info.minor}.dylib").is_file():
                current = os.environ.get("DYLD_LIBRARY_PATH", "")
                paths = [str(library_dir), *filter(None, current.split(os.pathsep))]
                os.environ["DYLD_LIBRARY_PATH"] = os.pathsep.join(dict.fromkeys(paths))
        return "verilator", ["--timing", "-Wno-fatal", "--public-flat-rw", "-CFLAGS", "-std=c++17"]
    raise ValueError("PYTHON_SIM must be verilator or icarus/iverilog")


def run_cases(ip, sources, toplevel, test_module, test_dir, cases, env_name, plusargs=(), extra_env=None):
    """Build and run test_module on toplevel for each {case: parameters}; the case name in env_name, plus
    plusargs / extra_env for every case. COV_DIR (scripts/run_cov.sh): Verilator coverage files."""
    from cocotb_tools.runner import get_results, get_runner
    simulator, build_args = simulator_config()
    cov_dir = os.environ.get("COV_DIR") if simulator == "verilator" else None
    if cov_dir:
        build_args = [*build_args, "--coverage"]
    root = Path(os.environ.get("COCOTB_BUILD_ROOT", tempfile.gettempdir())) / "digital-ip-cocotb" / ip
    failed, crashed = [], []
    for case, parameters in cases.items():
        build_dir = root / simulator / case
        build_dir.mkdir(parents=True, exist_ok=True)
        runner = get_runner(simulator)
        runner.build(sources=sources, hdl_toplevel=toplevel, parameters=parameters, build_args=build_args,
                     build_dir=build_dir, always=True, timescale=("1ns", "1ps"))
        args = list(plusargs) + ([f"+verilator+coverage+file+{cov_dir}/{ip}_cocotb_{case}.dat"] if cov_dir else [])
        try:
            results = runner.test(hdl_toplevel=toplevel, test_module=test_module, build_dir=build_dir,
                                  test_dir=test_dir, plusargs=args, extra_env={**(extra_env or {}), env_name: case})
        except SystemExit as e:                                   # the simulator's exit code was not 0
            results = Path(test_dir) / "results.xml"
            try:
                n_tests, n_fail = get_results(results)
            except RuntimeError:
                n_tests, n_fail = 0, 1
            if simulator == "icarus" and e.code == -11 and n_tests and not n_fail:
                # Icarus 14.0 devel (s20260301) segfaults at exit after a run that wrote memories from cocotb-
                # driven signals (reproduced with an 8-line module); every test of this case has passed
                print(f"{ip} cocotb: WARNING case {case}: all {n_tests} tests passed, then Icarus crashed at exit "
                      "(signal 11, simulator defect)")
                crashed.append(case)
                continue
            failed.append(case)
            continue
        _, fails = get_results(results)
        if fails:
            failed.append(case)
    if failed:
        raise SystemExit(f"{ip} cocotb: FAILED in {', '.join(failed)}")
    note = f"; Icarus exit crash after passing: {', '.join(crashed)}" if crashed else ""
    print(f"{ip} cocotb: PASSED ({', '.join(cases)}{note})")


async def run_frames(dut, rng, frames, n_out=None, on_frame=None, gap=0.3, bp=0.3, each_clock=None, limit=40,
                     after_out_sof=False):
    """Frames (lists of beats (tdata, tlast, tuser)) back to back into s_tdata / s_tvalid / s_tlast / s_tuser
    (s_tready from the block), the output collected from m_tdata / m_tvalid / m_tlast / m_tuser with m_tready
    driven. Inputs change after the falling edge, handshakes are sampled 1 ns later. on_frame(f) runs in the clock
    frame f's first beat is first presented (the frame-sampled configuration); each_clock(dut) after every sample.
    gap / bp: the probability of no input beat / no output ready in a clock. after_out_sof: frame f's first beat
    (and on_frame(f)) waits until the first output beat of every earlier frame has left - for blocks that take a
    frame's settings with its first output pixel, which for a frame of few lines comes after its last input beat.
    Returns [(tdata, tlast, tuser)] once
    n_out beats (default: as many as went in) came out; raises after limit clocks per beat."""
    beats = [(f, b) for f, fr in enumerate(frames) for b in fr]
    n_out = len(beats) if n_out is None else n_out
    out = []
    k = 0
    started = -1
    out_sofs = 0
    for _ in range(limit * (len(beats) + n_out) + 2000):
        await FallingEdge(dut.clk)
        dut.m_tready.value = int(rng.random() >= bp)
        valid = 0
        if k < len(beats) and (not after_out_sof or beats[k][0] == started or out_sofs >= beats[k][0]):
            f, (d, last, user) = beats[k]
            if f != started and on_frame is not None:
                on_frame(f)
            started = f
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = d, last, user
            valid = int(rng.random() >= gap)
        dut.s_tvalid.value = valid
        await Timer(1, unit="ns")
        if valid and dut.s_tready.value:
            k += 1
        if dut.m_tvalid.value and dut.m_tready.value:
            out.append((int(dut.m_tdata.value), int(dut.m_tlast.value), int(dut.m_tuser.value)))
            out_sofs += out[-1][2]
        if each_clock is not None:
            each_clock(dut)
        if k == len(beats) and len(out) >= n_out:
            break
    dut.s_tvalid.value = 0
    if k < len(beats) or len(out) < n_out:
        raise TimeoutError(f"run_frames: {k} of {len(beats)} beats in, {len(out)} of {n_out} out")
    return out


def frame_beats(pix, pack):
    """The beats of a frame (h x w array of pixels; pack(pixel) -> tdata), tuser on the first, tlast at line ends."""
    h, w = pix.shape[:2]
    return [(pack(pix[y, x]), int(x == w - 1), int(x == 0 and y == 0)) for y in range(h) for x in range(w)]

