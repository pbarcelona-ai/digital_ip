"""Build and run the fixed_recip cocotb test (fixed_recip_tb.py: the RTL against the model). Environment: PYTHON_SIM (verilator,
default, or icarus), RECIP_N, RECIP_SEED, RECIP_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from fixed_recip_tb import CASES                                       # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("fixed_recip", "fixed_recip", "fixed_recip_tb", CASES, "RECIP_CASE")
