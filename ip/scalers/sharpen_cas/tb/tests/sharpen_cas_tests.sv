// ***************
// Filename: sharpen_cas_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_sharpen_cas testbench
//   (sharpen_cas_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     ip_configure  Programs the IP-specific registers before each test (hook
//                   of the shared scaler suite)
// Date: 2026-10-08
// ***************
  task automatic ip_configure();
    axil_write(12'h040, sharp);
    axil_check(12'h040, sharp);
    ctrl_bits = {30'd0, bypass, 1'b0};             // BYPASS, written together with ENABLE
  endtask
