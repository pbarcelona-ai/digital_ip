# Multiply-Accumulate Unit

**Type:** arithmetic IP

`mac` computes `a * b + acc` with one-cycle valid latency. Fixed-point mode independently configures operand, accumulator, and output widths and signedness. `A_FRAC_BITS`, `B_FRAC_BITS`, and `ACC_FRAC_BITS` specify the binary points; product alignment uses round-to-nearest-even when shifting right. The result can saturate to the configured output range, with overflow and inexact flags.

Set `FLOATING_POINT=1` for IEEE-754 binary32 fused multiply-add. Floating-point operands and result must all be 32 bits. The fused result is rounded once to nearest-even and reports overflow, underflow, inexact, and invalid-operation flags. NaNs are returned as the canonical quiet NaN.

Run `make test` from this directory to run both the SystemVerilog bench and the Python reference bench. Select the Python simulator with `make python-test PYTHON_SIM=verilator|iverilog|vcs|questa`; Verilator is the default, and `icarus` is also accepted as an alias for `iverilog`. VCS and Questa use Cocotb vendor runners and require those simulators and licenses; they are not tested locally. The self-checking benches cover signed and unsigned fixed point, fractional alignment, rounding, saturation, exact fused precision, subnormal results, overflow, and invalid operations.