"""Build and run the py_core cocotb tests (py_core_tb.py: the RTL against the golden model) in the v1
configuration (the parameter defaults) and the v2 configuration of video_processor (CODE_AW 15, a 64-word
stack, 32 locals and frames, 256 globals). Run by scripts/run_sim.sh after the SystemVerilog testbench.
Environment: PYTHON_SIM (verilator, default, or icarus), PYCORE_N random programs per test, PYCORE_SEED,
COV_DIR (Verilator coverage files, from scripts/run_cov.sh)."""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
SHARED = MODULE.parents[1] / "shared" / "src" / "interfaces"
BUILD_ROOT = Path(os.environ.get("COCOTB_BUILD_ROOT", tempfile.gettempdir())) / "digital-ip-cocotb" / "py_core"
SOURCES = [MODULE / "src/py_core_pkg.sv", SHARED / "axil_if.sv", MODULE / "src/py_core.sv",
           TEST_DIR / "py_core_cocotb_top.sv"]

sys.path.insert(0, str(TEST_DIR))
from py_core_tb import CASES                                   # noqa: E402  (the parameters of each case)


def simulator_config():
    """(runner name, build arguments) for PYTHON_SIM."""
    name = os.environ.get("PYTHON_SIM", "verilator").lower()
    if name in {"icarus", "iverilog"}:
        return "icarus", []
    if name == "verilator":
        if sys.platform == "darwin":                            # the Python library for the embedded cocotb
            library_dir = Path(sys.executable).resolve().parent.parent / "lib"
            python_library = library_dir / f"libpython{sys.version_info.major}.{sys.version_info.minor}.dylib"
            if python_library.is_file():
                current = os.environ.get("DYLD_LIBRARY_PATH", "")
                paths = [str(library_dir), *filter(None, current.split(os.pathsep))]
                os.environ["DYLD_LIBRARY_PATH"] = os.pathsep.join(dict.fromkeys(paths))
        # the monitor reads the core's state (u_core.st, u_core.ipc)
        return "verilator", ["--timing", "-Wno-fatal", "--public-flat-rw", "-CFLAGS", "-std=c++17"]
    raise ValueError("PYTHON_SIM must be verilator or icarus/iverilog")


def main() -> None:
    simulator, build_args = simulator_config()
    cov_dir = os.environ.get("COV_DIR") if simulator == "verilator" else None
    if cov_dir:
        build_args = [*build_args, "--coverage"]
    failed = []
    for case, parameters in CASES.items():
        build_dir = BUILD_ROOT / simulator / case
        build_dir.mkdir(parents=True, exist_ok=True)
        code, const = build_dir / "code.hex", build_dir / "const.hex"
        runner = get_runner(simulator)
        runner.build(sources=SOURCES, hdl_toplevel="py_core_cocotb_top", parameters=parameters,
                     build_args=build_args, build_dir=build_dir, always=True, timescale=("1ns", "1ps"))
        plusargs = [f"+CODE={code}", f"+CONST={const}"]
        if cov_dir:
            plusargs.append(f"+verilator+coverage+file+{cov_dir}/py_core_cocotb_{case}.dat")
        results = runner.test(hdl_toplevel="py_core_cocotb_top", test_module="py_core_tb", build_dir=build_dir,
                              test_dir=TEST_DIR, plusargs=plusargs,
                              extra_env={"PYCORE_CASE": case, "PYCORE_CODE": str(code), "PYCORE_CONST": str(const)})
        _, fails = get_results(results)
        if fails:
            failed.append(case)
    if failed:
        raise SystemExit(f"py_core cocotb: FAILED in {', '.join(failed)}")
    print("py_core cocotb: PASSED (v1, v2)")


if __name__ == "__main__":
    main()
