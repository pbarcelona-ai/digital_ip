"""Build and run MAC reference tests in signed, unsigned, and binary32 modes."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile

from cocotb_tools.runner import get_runner


MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
BUILD_ROOT = Path(os.environ.get("COCOTB_BUILD_ROOT", tempfile.gettempdir())) / "digital-ip-cocotb" / "mac"
SOURCES = [MODULE / "src/mac.sv", MODULE / "src/fp32_fma.sv", TEST_DIR / "mac_cocotb_top.sv"]

CASES = {
    "signed_fixed": {
        "A_WIDTH": 8, "B_WIDTH": 8, "ACC_WIDTH": 16, "OUT_WIDTH": 8,
        "A_SIGNED": 1, "B_SIGNED": 1, "ACC_SIGNED": 1, "OUT_SIGNED": 1,
        "A_FRAC_BITS": 4, "B_FRAC_BITS": 4, "ACC_FRAC_BITS": 4, "SATURATE": 1,
    },
    "unsigned_fixed": {
        "A_WIDTH": 8, "B_WIDTH": 8, "ACC_WIDTH": 16, "OUT_WIDTH": 16,
        "A_SIGNED": 0, "B_SIGNED": 0, "ACC_SIGNED": 0, "OUT_SIGNED": 0,
    },
    "binary32": {
        "A_WIDTH": 32, "B_WIDTH": 32, "ACC_WIDTH": 32, "OUT_WIDTH": 32,
        "FLOATING_POINT": 1,
    },
}


def simulator_config():
    name = os.environ.get("PYTHON_SIM", "verilator").lower()
    if name in {"icarus", "iverilog"}:
        return "icarus", []
    if name == "verilator":
        if sys.platform == "darwin":
            library_dir = Path(sys.executable).resolve().parent.parent / "lib"
            python_library = library_dir / f"libpython{sys.version_info.major}.{sys.version_info.minor}.dylib"
            if python_library.is_file():
                BUILD_ROOT.mkdir(parents=True, exist_ok=True)
                library_link = BUILD_ROOT / "lib"
                if not library_link.exists() and not library_link.is_symlink():
                    library_link.symlink_to(library_dir, target_is_directory=True)
                current = os.environ.get("DYLD_LIBRARY_PATH", "")
                paths = [str(library_dir), *filter(None, current.split(os.pathsep))]
                os.environ["DYLD_LIBRARY_PATH"] = os.pathsep.join(dict.fromkeys(paths))
        return "verilator", ["--timing", "-Wno-fatal"]
    if name in {"modelsim", "questa", "questasim"}:
        return "questa", []
    if name == "vcs":
        return name, []
    raise ValueError("PYTHON_SIM must be verilator, icarus/iverilog, vcs, modelsim, questa, or questasim")


def main() -> None:
    simulator, build_args = simulator_config()
    for case, parameters in CASES.items():
        build_dir = BUILD_ROOT / case
        runner = get_runner(simulator)
        runner.build(
            sources=SOURCES,
            hdl_toplevel="mac_cocotb_top",
            parameters=parameters,
            build_args=build_args,
            build_dir=build_dir,
            always=True,
            timescale=("1ns", "1ps"),
        )
        runner.test(
            hdl_toplevel="mac_cocotb_top",
            test_module="mac_tb",
            build_dir=build_dir,
            test_dir=TEST_DIR,
            extra_env={"MAC_CASE": case},
        )


if __name__ == "__main__":
    main()