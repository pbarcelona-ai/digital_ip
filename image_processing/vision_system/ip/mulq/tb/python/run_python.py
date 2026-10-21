"""Build and run the mulq_s cocotb test (mulq_s_tb.py: the RTL against the model). Run by the block's flow after
its SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or icarus), MULQ_N, MULQ_SEED,
MULQ_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from mulq_s_tb import CASES                                       # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("mulq", "mulq_s", "mulq_s_tb", CASES, "MULQ_CASE")
