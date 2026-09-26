# scaler_tb_lib

Verification support shared by all testbenches (include files, not RTL):

| File | Purpose |
|---|---|
| `src/scaler_tb_axil.svh` | Clock, reset, AXI4-Lite master signals and tasks (`axil_write`, `axil_read`, `axil_check`), error counters, watchdog (`+TIMEOUT_MS`), `finish_report` |
| `src/scaler_tb_lib.svh` | Video stream driver and checker with random stalls, test patterns, PPM (P6) reading and writing, plusarg handling (`tb_init`: `+IMG`, `+OUT_W`, `+OUT_H`, `+OUTDIR`, `+NO_PPM`), coordinate reference helpers, `run_test`, the standard size sweep and the `+IMG` suite. The including testbench supplies `golden_pixel()` and `ip_configure()` |
| `src/scaler_coef_gen.svh` | SystemVerilog polyphase coefficient generator. It is bit-identical to `tools/scaler_coefs.py` (checked on 2,816 coefficients under both simulators), so no Python is needed to simulate |

Add `-I <path>/scaler_tb_lib/src` to the compile command. The files are written to run on Icarus Verilog 12 (`-g2012`), Verilator 5 (`--timing`) and commercial simulators. They avoid fork/join inside tasks, `break`, whole-array assignments and static-lifetime initialisers.
