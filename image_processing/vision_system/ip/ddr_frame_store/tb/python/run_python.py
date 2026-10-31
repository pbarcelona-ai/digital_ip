"""Build and run the ddr_frame_store cocotb test (ddr_frame_store_tb.py: ddr_frame_store with ddr_ctrl and ddr_mem
against their models) for the parameter sets of ddr_frame_store_tb.CASES. Environment: PYTHON_SIM (verilator,
default, or icarus), DFS_N, DFS_SEED, DFS_CASES (comma-separated case names; default all), COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from ddr_frame_store_tb import CASES, LIB_SOURCES                 # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("ddr_frame_store", "ddr_frame_store_cocotb_top", "ddr_frame_store_tb", CASES, "DFS_CASE",
                     extra_sources=[*LIB_SOURCES, "ddr_frame_store_cocotb_top.sv"])
