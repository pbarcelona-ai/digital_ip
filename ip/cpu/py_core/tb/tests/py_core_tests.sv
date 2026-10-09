// ***************
// Filename: py_core_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the py_core_tb testbench (py_core_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     emit         Tiny assembler
//     op0
//     op1
//     op2
//     clear_prog
//     check        Helpers
//     run
//     expect_trap
// Date: 2026-10-08
// ***************
  // Tiny assembler: emit bytes at 'here'
  task automatic emit(input logic [7:0] b);
    code[here] = b;
    here++;
  endtask

  task automatic op0(input opcode_e o);
    emit(o);
  endtask

  task automatic op1(input opcode_e o, input logic [7:0] a);
    emit(o);
    emit(a);
  endtask

  task automatic op2(input opcode_e o, input logic [15:0] a);
    emit(o);
    emit(a[7:0]);
    emit(a[15:8]);
  endtask

  task automatic clear_prog();
    for (int i = 0; i < 2**CODE_AW; i++) code[i] = 8'hFF;
    here = 0;
  endtask

  // ---------------- helpers ----------------
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run(output bit trapped);
    @(posedge clk);
    start <= 1;
    @(posedge clk);
    start <= 0;
    for (int t = 0; t < 20000; t++) begin
      @(posedge clk);
      if (done || trap) begin
        trapped = trap;
        return;
      end
    end
    errors++;
    $display("ERROR: timeout");
    trapped = 0;
  endtask

  task automatic expect_trap(input string name, input trap_e c, input int pc);
    bit tr;
    run(tr);
    check(tr && cause == c && trap_pc == pc, $sformatf("%s: trap=%0b cause=%0d pc=%0d", name, tr, cause, trap_pc));
  endtask
