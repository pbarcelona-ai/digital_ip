"""Build and run the ext_frame_buffer cocotb test (ext_frame_buffer_tb.py: the RTL against the model, clock
exact) for the parameter sets of ext_frame_buffer_tb.CASES. Environment: PYTHON_SIM (verilator, default, or
icarus), EFB_N, EFB_SEED, EFB_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from ext_frame_buffer_tb import CASES                             # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("ext_frame_buffer", "ext_frame_buffer_cocotb_top", "ext_frame_buffer_tb", CASES, "EFB_CASE",
                     extra_sources=["ext_frame_buffer_cocotb_top.sv"])
