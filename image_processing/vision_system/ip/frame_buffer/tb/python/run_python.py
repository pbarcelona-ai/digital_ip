"""Build and run the frame_buffer cocotb test (frame_buffer_tb.py: the RTL against the model). Environment: PYTHON_SIM (verilator,
default, or icarus), FB_N, FB_SEED, FB_CASES, COV_DIR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "tb" / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vs_cocotb                                                  # noqa: E402
from frame_buffer_tb import CASES                                       # noqa: E402

if __name__ == "__main__":
    vs_cocotb.run_ip("frame_buffer", "frame_buffer_cocotb_top", "frame_buffer_tb", CASES, "FB_CASE",
                     extra_sources=["frame_buffer_cocotb_top.sv"])
