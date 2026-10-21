"""Build and run the bilinear cocotb test (bilinear_tb.py: the RTL against the model). Environment: PYTHON_SIM
(verilator, default, or icarus), BIL_N, BIL_SEED, BIL_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from bilinear_tb import CASES                                     # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("bilinear", "bilinear", "bilinear_tb", CASES, "BIL_CASE")
