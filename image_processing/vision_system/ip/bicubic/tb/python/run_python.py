"""Build and run the bicubic cocotb test (bicubic_tb.py: the RTL against the model). Environment: PYTHON_SIM
(verilator, default, or icarus), BIC_N, BIC_SEED, BIC_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from bicubic_tb import CASES                                      # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("bicubic", "bicubic", "bicubic_tb", CASES, "BIC_CASE")
