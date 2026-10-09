// ***************
// Filename: fixed_recip_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_fixed_recip testbench
//   (tb_fixed_recip.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
// Date: 2026-10-08
// ***************
  task automatic check(input logic [W-1:0] op, input string name);
    logic [63:0] expected64;
    logic [W-1:0] expected;
    begin
      // Independent reference: floor(2^32 / op), op=0 treated as the
      // documented saturate-to-all-ones case (mirrors the RTL's own
      // divisor==0 guard, which substitutes divisor=1 -- floor(2^32/1)
      // overflows W bits, so the RTL saturates; reproduce that here
      // rather than actually computing 2^32/0).
      if (op == 0) begin
        expected = {W{1'b1}};
      end else begin
        expected64 = (64'h1_0000_0000) / {32'h0, op};
        expected = (expected64 > {W{1'b1}}) ? {W{1'b1}} : expected64[W-1:0];
      end

      @(posedge clk);
      operand = op; start = 1;
      @(posedge clk); start = 0;
      wait (done);

      checks = checks + 1;
      if (result !== expected) begin
        $display("[%s] FAIL: operand=0x%08h -> result=0x%08h, expected=0x%08h",
                   name, op, result, expected);
        fails = fails + 1;
      end else begin
        $display("[%s] PASS: operand=0x%08h (%.6f) -> result=0x%08h (%.6f)",
                   name, op, $itor(op)/65536.0, result, $itor(result)/65536.0);
      end
      @(posedge clk);
    end
  endtask
