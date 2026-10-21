"""Build and run the py_soc cocotb tests (each the RTL against its golden model): py_sysctl (py_sysctl_tb.py),
py_stream_port (py_stream_port_tb.py; py_soc's 8-bit 16 / 16 ports and a 16-bit 4 / 2 port), then py_soc
itself (py_soc_tb.py: tb/programs/selftest.py, compiled here with pyc.py, from the boot to the watchdog reset,
clock for clock against py_soc_model + py_boot_model + py_core_model).
Run by scripts/run_test.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or
icarus), SYSCTL_CYCLES, SYSCTL_SEED, PORT_CYCLES, PORT_SEED, PYSOC_MAX_CLOCKS, COV_DIR."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
IP = MODULE.parents[1]
sys.path.insert(0, str(IP / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from py_sysctl_tb import CASES as SYSCTL_CASES                     # noqa: E402
from py_stream_port_tb import CASES as PORT_CASES                  # noqa: E402
from py_soc_tb import CASES as SOC_CASES                           # noqa: E402

SYSCTL_SOURCES = [IP / "shared/src/interfaces/axil_if.sv", IP / "shared/src/interfaces/regbus_if.sv",
                  IP / "bus/axi4_lite_slave/src/axi4_lite_slave.sv", MODULE / "src/include/py_sysctl_regs_if.sv",
                  MODULE / "src/include/py_sysctl_regs.sv", MODULE / "src/py_sysctl.sv",
                  MODULE / "src/py_sysctl_top.sv", TEST_DIR / "py_sysctl_cocotb_top.sv"]

PORT_SOURCES = [IP / "shared/src/interfaces/axil_if.sv", IP / "shared/src/interfaces/axis_if.sv",
                IP / "shared/src/interfaces/regbus_if.sv", IP / "bus/axi4_lite_slave/src/axi4_lite_slave.sv",
                IP / "shared/src/fifo/ip_axis_fifo.sv", MODULE / "src/include/py_stream_port_regs_if.sv",
                MODULE / "src/include/py_stream_port_regs.sv", MODULE / "src/py_stream_port.sv",
                MODULE / "src/py_stream_port_top.sv", TEST_DIR / "py_stream_port_cocotb_top.sv"]

SOC_SOURCES = build_f_sources(MODULE) + [IP / "shared/tb/lib/i2c_bfm.sv", IP / "shared/tb/lib/spi_flash_bfm.sv",
                                         TEST_DIR / "py_soc_cocotb_top.sv"]


PROGRAMS = {"selftest": "selftest", "bus": "soc_bus"}             # py_soc_tb case -> tb/programs/<name>.py


def firmware(name):
    """tb/programs/<name>.py compiled for py_soc (py_core v2, CODE_AW 15): the output prefix."""
    out = Path(os.environ.get("COCOTB_BUILD_ROOT", tempfile.gettempdir())) / "digital-ip-cocotb" / "py_soc" / "fw"
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(IP / "cpu/py_core/tools/pyc.py"), "--core", "2", "--code-aw", "15",
                    "-I", str(MODULE / "src"), str(MODULE / f"tb/programs/{name}.py"), "-o", str(out / name)],
                   check=True)
    return out / name


if __name__ == "__main__":
    run_cases("py_sysctl", SYSCTL_SOURCES, "py_sysctl_cocotb_top", "py_sysctl_tb", TEST_DIR, SYSCTL_CASES,
              "SYSCTL_CASE")
    run_cases("py_stream_port", PORT_SOURCES, "py_stream_port_cocotb_top", "py_stream_port_tb", TEST_DIR,
              PORT_CASES, "PORT_CASE")
    for case in SOC_CASES:
        fw = firmware(PROGRAMS[case])
        run_cases("py_soc", SOC_SOURCES, "py_soc_cocotb_top", "py_soc_tb", TEST_DIR, {case: {}}, "PYSOC_CASE",
                  plusargs=[f"+FLASH={fw}.flash.hex"], extra_env={"PYSOC_FW": str(fw)})
