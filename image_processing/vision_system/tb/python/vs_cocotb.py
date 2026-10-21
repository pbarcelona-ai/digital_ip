"""Shared helpers of the vision_system sub-block cocotb tests (ip/<block>/tb/python): paths to the models and
the library's cocotb_lib, and run_ip() which builds one block from its scripts/build.f and runs its test.
Stimulus convention of every test: inputs are set after the falling edge, outputs sampled 1 ns later; an output
sampled in loop iteration i holds the registers after rising edge i - 1, so a block of latency L shows the
response to iteration i's inputs in iteration i + L."""
from __future__ import annotations

import os
import sys
from pathlib import Path

VS = Path(__file__).resolve().parents[2]                          # image_processing/vision_system
LIB = VS.parents[1] / "ip" / "shared" / "tb" / "python"
sys.path.insert(0, str(LIB))
import cocotb_lib                                                 # noqa: E402

MODEL_DIRS = [VS / "model"] + sorted((VS / "ip").glob("*/model"))


def models():
    """Put the vision_system models (and ip/shared/pymodel) on sys.path."""
    cocotb_lib.model_path(*MODEL_DIRS)


def run_ip(ip, toplevel, test_module, cases, env_name, extra_sources=()):
    """Build ip/<ip> (its scripts/build.f, plus extra_sources) for each case and run test_module."""
    ip_dir = VS / "ip" / ip
    test_dir = ip_dir / "tb" / "python"
    sources = cocotb_lib.build_f_sources(ip_dir) + [test_dir / s for s in extra_sources]
    sel = os.environ.get(env_name + "S", ",".join(cases)).split(",")
    cocotb_lib.run_cases(f"vision_system_{ip}", sources, toplevel, test_module, test_dir,
                         {k: v for k, v in cases.items() if k in sel}, env_name,
                         extra_env={"PYTHONPATH": os.pathsep.join([str(VS / "tb" / "python"), str(LIB)])})
