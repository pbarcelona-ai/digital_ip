"""Build and run the coord_gen cocotb test (coord_gen_tb.py: the RTL against the model). Environment: PYTHON_SIM (verilator,
default, or icarus), CG_N, CG_SLOW, CG_SEED, CG_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from coord_gen_tb import CASES                                       # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("coord_gen", "coord_gen_cocotb_top", "coord_gen_tb", CASES, "CG_CASE", extra_sources=['coord_gen_cocotb_top.sv'])
