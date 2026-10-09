// ***************
// Filename: py_core_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for py_core. Hand-assembles small
//   programs into a byte-wide code memory and runs them against a
//   behavioral AXI4-Lite slave with random ready/valid delays. Tests a
//   while-loop that writes a GPIO register through mem32 (the Python source
//   is shown next to the bytecode), each trap cause (overflow, type,
//   illegal opcode, bus error), a full 32-bit register read, and resume
//   past an emulated instruction, recursive calls, call depth overflow
//   and RETURN without a caller. Interrupts are covered by py_soc_tb. Prints TEST PASSED on success.
//   The test tasks are in tests/py_core_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module py_core_tb;
  import py_core_pkg::*;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;

  localparam int CODE_AW = 12, CONST_AW = 4;
  logic start = 0, resume = 0, busy, done, trap; logic [CODE_AW-1:0] resume_pc = '0;
  logic [33:0] result; trap_e cause; logic [CODE_AW-1:0] trap_pc; logic [7:0] trap_op;
  logic [CODE_AW-1:0] code_addr; logic [7:0] code_q; logic [CONST_AW-1:0] const_addr; logic [33:0] const_q;
  logic [31:0] awaddr, wdata, araddr, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  py_core #(.CODE_AW(CODE_AW), .CONST_AW(CONST_AW)) dut (.clk, .rst_n,
    .start_i(start), .resume_i(resume), .resume_pc_i(resume_pc), .busy_o(busy), .done_o(done), .result_o(result),
    .trap_o(trap), .trap_cause_o(cause), .trap_pc_o(trap_pc), .trap_op_o(trap_op), .irq_i(1'b0), .in_irq_o(),
    .code_addr_o(code_addr), .code_data_i(code_q), .const_addr_o(const_addr), .const_data_i(const_q),
    .m_axil_awaddr(awaddr), .m_axil_awvalid(awvalid), .m_axil_awready(awready), .m_axil_wdata(wdata), .m_axil_wstrb(wstrb),
    .m_axil_wvalid(wvalid), .m_axil_wready(wready), .m_axil_bresp(bresp), .m_axil_bvalid(bvalid), .m_axil_bready(bready),
    .m_axil_araddr(araddr), .m_axil_arvalid(arvalid), .m_axil_arready(arready), .m_axil_rdata(rdata), .m_axil_rresp(rresp),
    .m_axil_rvalid(rvalid), .m_axil_rready(rready));

  // ---------------- code / const memories ----------------
  logic [7:0] code [2**CODE_AW]; logic [33:0] cpool [2**CONST_AW];
  always_ff @(posedge clk) begin code_q <= code[code_addr]; const_q <= cpool[const_addr]; end

  // used by task emit (tests/py_core_tests.sv)
  int here;

  // ---------------- AXI4-Lite slave model ----------------
  // 0x1000 GPIO_OUT (RW), 0x1004 ID (RO, 0x8000_0000: needs all 32 bits unsigned),
  // 0xBAD0 returns SLVERR, everything else is a 1K-word RAM (address bits [11:2]).
  localparam int GPIO = 'h1000, ID = 'h1004, BAD = 'hBAD0;
  logic [31:0] sram [1024]; logic [31:0] gpio_log [$];
  logic aw_seen, w_seen; logic [31:0] aw_q, w_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      awready <= 0; wready <= 0; bvalid <= 0; arready <= 0; rvalid <= 0; aw_seen <= 0; w_seen <= 0;
    end else begin
      awready <= ($urandom % 3 == 0) && !aw_seen; wready <= ($urandom % 3 == 0) && !w_seen; arready <= ($urandom % 3 == 0) && !rvalid && !arready;
      if (awvalid && awready) begin aw_seen <= 1; aw_q <= awaddr; awready <= 0; end
      if (wvalid && wready)   begin w_seen  <= 1; w_q  <= wdata;  wready  <= 0; end
      if (aw_seen && w_seen && !bvalid) begin
        bvalid <= 1; bresp <= (aw_q == BAD) ? 2'b10 : 2'b00;
        if (aw_q == GPIO) gpio_log.push_back(w_q);
        if (aw_q != BAD) sram[aw_q[11:2]] = w_q;
      end
      if (bvalid && bready) begin bvalid <= 0; aw_seen <= 0; w_seen <= 0; end
      if (arvalid && arready && !rvalid) begin
        rvalid <= 1; rresp <= (araddr == BAD) ? 2'b10 : 2'b00; arready <= 0;
        rdata  <= (araddr == ID) ? 32'h8000_0000 : sram[araddr[11:2]];
      end
      if (rvalid && rready) rvalid <= 0;
    end
  end

  // used by task check (tests/py_core_tests.sv)
  int errors = 0;
  // test tasks: tests/py_core_tests.sv
  `include "py_core_tests.sv"

  initial begin
    bit tr; int loop, end_l, fix_at, tri_at, base_l;
    foreach (sram[i]) sram[i] = 0;
    if ($test$plusargs("vcd")) begin $dumpfile("py_core_tb.vcd"); $dumpvars(0, py_core_tb); end
    cpool[0] = mk_small(GPIO); cpool[1] = mk_small(33'h0_FFFF_FFFF); cpool[2] = 34'h0_0000_2000;  // largest small int; heap pointer
    cpool[3] = mk_small(ID);   cpool[4] = mk_small(BAD);
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

    // ---- 1. GPIO loop ----------------------------------------------
    //   i = 0
    //   while i < 10:
    //       mem32[GPIO] = i << 4
    //       i = i + 1
    //   return mem32[GPIO] + 100
    clear_prog();
    op1(OP_LOAD_SMALL, 0); op1(OP_STORE_FAST, 0);
    loop = here;
    op1(OP_LOAD_FAST, 0); op1(OP_LOAD_SMALL, 10); op0(OP_COMPARE_LT);
    end_l = here; op2(OP_POP_JUMP_IF_FALSE, 0);              // patched below
    op1(OP_LOAD_CONST, 0); op1(OP_LOAD_FAST, 0); op1(OP_LOAD_SMALL, 4); op0(OP_BINARY_LSHIFT); op0(OP_MEM32_STORE);
    op1(OP_LOAD_FAST, 0); op1(OP_LOAD_SMALL, 1); op0(OP_BINARY_ADD); op1(OP_STORE_FAST, 0);
    op2(OP_JUMP, loop);
    code[end_l+1] = here[7:0]; code[end_l+2] = here[15:8];
    op1(OP_LOAD_CONST, 0); op0(OP_MEM32_LOAD); op1(OP_LOAD_SMALL, 100); op0(OP_BINARY_ADD); op0(OP_RETURN_VALUE);
    run(tr);
    check(!tr && done, "gpio loop: did not complete");
    check(result == mk_small(144 + 100), $sformatf("gpio loop: result %h", result));
    check(gpio_log.size() == 10, $sformatf("gpio loop: %0d writes", gpio_log.size()));
    foreach (gpio_log[i]) check(gpio_log[i] == i << 4, $sformatf("gpio write %0d = %h", i, gpio_log[i]));

    // ---- 2. negative numbers and compares ------------------------------
    //   return (-5 - 7) == -12
    clear_prog();
    op1(OP_LOAD_SMALL, -5); op1(OP_LOAD_SMALL, 7); op0(OP_BINARY_SUB); op1(OP_LOAD_SMALL, -12); op0(OP_COMPARE_EQ); op0(OP_RETURN_VALUE);
    run(tr); check(!tr && result == PY_TRUE, $sformatf("compare: result %h", result));

    // ---- 3. overflow -> bigint slow path ---------------------------
    clear_prog();
    op1(OP_LOAD_CONST, 1); op1(OP_LOAD_SMALL, 1); op0(OP_BINARY_ADD); op0(OP_RETURN_VALUE);
    expect_trap("overflow", TRAP_OVERFLOW, 4);

    // ---- 4. heap object operand -> type slow path ------------------
    clear_prog();
    op1(OP_LOAD_CONST, 2); op1(OP_LOAD_SMALL, 1); op0(OP_BINARY_ADD); op0(OP_RETURN_VALUE);
    expect_trap("type", TRAP_TYPE, 4);

    // ---- 5. bus error on store -------------------------------------
    clear_prog();
    op1(OP_LOAD_CONST, 4); op1(OP_LOAD_SMALL, 1); op0(OP_MEM32_STORE); op0(OP_LOAD_NONE); op0(OP_RETURN_VALUE);
    expect_trap("bus", TRAP_BUS, 4);

    // ---- 6. full 32-bit register reads back unsigned -----------------
    clear_prog();
    op1(OP_LOAD_CONST, 3); op0(OP_MEM32_LOAD); op0(OP_RETURN_VALUE);
    run(tr); check(!tr && result == mk_small(33'h0_8000_0000), $sformatf("wide read: result %h", result));

    // ---- 7. illegal opcode, helper emulates it and resumes ------------
    clear_prog();
    op1(OP_LOAD_SMALL, 40); fix_at = here; emit(8'h77); op1(OP_LOAD_SMALL, 2); op0(OP_BINARY_ADD); op0(OP_RETURN_VALUE);
    expect_trap("illegal", TRAP_ILLEGAL, fix_at);
    check(trap_op == 8'h77, "illegal: trap_op");
    @(posedge clk); resume_pc <= fix_at + 1; resume <= 1; @(posedge clk); resume <= 0; @(posedge clk);
    for (int t = 0; t < 1000 && !(done || trap); t++) @(posedge clk);
    check(done && result == mk_small(42), $sformatf("resume: result %h", result));

    // ---- 8. recursion: def tri(n): return 0 if n == 0 else n + tri(n - 1) ----
    for (int depth = 10; depth <= 20; depth += 10) begin
      clear_prog();
      op1(OP_LOAD_SMALL, depth[7:0]); tri_at = here; op2(OP_CALL, 0); op0(OP_RETURN_VALUE);
      code[tri_at+1] = here[7:0]; code[tri_at+2] = here[15:8]; tri_at = here;
      op1(OP_STORE_FAST, 0);
      op1(OP_LOAD_FAST, 0); op1(OP_LOAD_SMALL, 0); op0(OP_COMPARE_EQ); base_l = here; op2(OP_POP_JUMP_IF_FALSE, 0);
      op1(OP_LOAD_SMALL, 0); op0(OP_RETURN);
      code[base_l+1] = here[7:0]; code[base_l+2] = here[15:8];
      op1(OP_LOAD_FAST, 0); op1(OP_LOAD_FAST, 0); op1(OP_LOAD_SMALL, 1); op0(OP_BINARY_SUB);
      fix_at = here; op2(OP_CALL, tri_at); op0(OP_BINARY_ADD); op0(OP_RETURN);
      if (depth == 10) begin
        run(tr); check(!tr && done && result == mk_small(55), $sformatf("tri(10): result %h trap=%0b cause=%0d", result, tr, cause));
      end else
        expect_trap("call depth", TRAP_STACK, fix_at);        // 16 frames: main + 15 calls
    end

    // ---- 9. RETURN with no caller ----
    clear_prog();
    op1(OP_LOAD_SMALL, 1); op0(OP_RETURN);
    expect_trap("return at frame 0", TRAP_FRAME, 2);

    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
