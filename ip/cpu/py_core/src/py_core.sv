// ***************
// Filename: py_core.sv
// Author: FPGA Cores 4 U
// Description: Python-bytecode stack machine. Executes the opcode
//   set in py_core_pkg directly: 33-bit small-int arithmetic, compares,
//   locals, globals, jumps, function calls, native mem32 load/store over an
//   AXI4-Lite master, and one level of interrupts. Anything outside the fast path
//   (heap objects, bigints, unknown opcodes) raises a trap and the core
//   stalls with trap_pc_o at the faulting instruction, so a helper
//   (microcode or a small RISC-V) can emulate it and resume at
//   resume_pc_i.
//
//   Calls - CALL pushes the return address on a return stack and gives the
//   callee a fresh frame of N_LOCALS locals (frame 0 is the main program).
//   Arguments travel on the operand stack: the callee's first instructions
//   pop them into its locals. RETURN pops the frame and leaves the return
//   value on the operand stack. N_FRAMES bounds the call depth (deeper is
//   TRAP_STACK, i.e. RecursionError). Locals are not cleared on entry; the
//   compiler only reads locals it has assigned.
//
//   Interrupts - irq_i is a level input, sampled between instructions when
//   IRQ_ENABLE has run, no handler is active and a frame is free. Entry is
//   a call to the SET_IRQ_VECTOR address that also saves the operand stack
//   depth; RETURN_FROM_IRQ returns and restores it. Handlers may call
//   functions. Globals are shared, which is how handlers pass data to the
//   main program. No nesting: irq_i is ignored while a handler runs.
//
//   WAIT_IRQ (v2) stops the core until irq_i is high, whether interrupts
//   are enabled or not; with interrupts enabled the handler is entered at
//   the next instruction boundary. RETURN_FROM_IRQ with fewer operands on
//   the stack than at entry is TRAP_STACK.
//
//   Arithmetic (v2) - BINARY_MUL: 33 x 33-bit product, 2 extra clocks;
//   BINARY_FLOORDIV / BINARY_MOD: Python semantics (the quotient rounds
//   towards minus infinity, the remainder has the divisor's sign), a radix-2
//   restoring divider on the magnitudes, 32 extra clocks; a zero divisor is
//   TRAP_DIV0; a result outside the small-int range is TRAP_OVERFLOW.
//
//   Code memory - byte-wide, synchronous read, 1 clock latency (addresses
//   wrap at 2**CODE_AW, also for operand bytes). Constant pool - VW-bit
//   words, same timing. Operand stack, locals, globals - flops; locals - one
//   memory with combinational read (LUT RAM).
//   Clock - clk only. Reset - synchronous rst_n (active low).
//   Throughput - multi-cycle FSM, 3 + operand-byte clocks per instruction
//   (fetch, opcode, operands, execute; LOAD_CONST + 1, BINARY_MUL + 2,
//   FLOORDIV / MOD + 32), plus the bus handshake for mem32. Matches the
//   golden model ip/cpu/py_core/model/py_core_model.py instruction for
//   instruction and clock for clock (tb/python). Version 2.0.0.
// Date: 2026-10-20
module py_core #(
  parameter int CODE_AW     = 13,  // code memory size = 2**CODE_AW bytes
  parameter int CONST_AW    = 8,   // constant pool = 2**CONST_AW words
  parameter int STACK_DEPTH = 32,
  parameter int N_LOCALS    = 16,  // per frame
  parameter int N_FRAMES    = 16,  // call depth, including the main program and a handler
  parameter int N_GLOBALS   = 32
) (
  input  logic                clk,
  input  logic                rst_n,
  // Control / status
  input  logic                start_i,        // pulse: begin at pc = 0
  input  logic                resume_i,       // pulse: leave TRAP, continue at resume_pc_i
  input  logic [CODE_AW-1:0]  resume_pc_i,    // trap_pc_o to retry, or past the emulated op
  output logic                busy_o,
  output logic                done_o,         // held after RETURN_VALUE
  output logic [33:0]         result_o,       // tagged return value
  output logic                trap_o,         // held while trapped
  output py_core_pkg::trap_e  trap_cause_o,
  output logic [CODE_AW-1:0]  trap_pc_o,
  output logic [7:0]          trap_op_o,
  // Interrupt
  input  logic                irq_i,          // level, from the interrupt controller
  output logic                in_irq_o,       // a handler is running
  // Code memory (byte-wide, synchronous read)
  output logic [CODE_AW-1:0]  code_addr_o,
  input  logic [7:0]          code_data_i,
  // Constant pool (synchronous read)
  output logic [CONST_AW-1:0] const_addr_o,
  input  logic [33:0]         const_data_i,
  // AXI4-Lite master: peripherals and external registers
  // m_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 32
  axil_if.master m_axil
);
  import py_core_pkg::*;
  localparam int SP_W = $clog2(STACK_DEPTH + 1);
  localparam int LB_W = $clog2(N_LOCALS);
  localparam int FP_W = $clog2(N_FRAMES);
  localparam int SI_W = $clog2(STACK_DEPTH);           // operand stack index
  localparam int GI_W = $clog2(N_GLOBALS);             // global index
  if (N_GLOBALS < 2 || N_GLOBALS > 256 || (N_GLOBALS & (N_GLOBALS - 1)) != 0) begin : g_chk_ng
    $error("py_core: N_GLOBALS must be a power of two, 2 to 256 (8-bit operand)");
  end
  if (N_LOCALS > 256) begin : g_chk_nl8
    $error("py_core: N_LOCALS must be <= 256 (8-bit operand)");
  end
  if (N_LOCALS < 2 || (N_LOCALS & (N_LOCALS - 1)) != 0) begin : g_chk_nl
    $error("py_core: N_LOCALS must be a power of two >= 2");
  end
  if (CODE_AW > 16) begin : g_chk_aw
    $error("py_core: CODE_AW must be <= 16 (16-bit jump targets)");
  end

  typedef enum logic [3:0] {S_IDLE, S_FETCH, S_OP, S_ARG0, S_ARG1, S_EXEC, S_CONST, S_WR, S_RD, S_DONE, S_TRAP,
                            S_MUL, S_DIV, S_WAIT} state_e;
  state_e st;

  logic [CODE_AW-1:0] pc, ipc;          // ipc: address of the current instruction
  logic [7:0]         op;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0]        arg;              // operand bytes; jumps use arg[CODE_AW-1:0], indices arg[7:0]
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0]         nargs;
  pyval_t             stk [STACK_DEPTH];
  logic [SP_W-1:0]    sp;               // number of entries; TOS = stk[sp-1]
  pyval_t             locals [N_FRAMES*N_LOCALS];  // frame fp uses words fp*N_LOCALS +: N_LOCALS
  logic [CODE_AW-1:0] rstk [N_FRAMES];             // return address of each call
  logic [FP_W-1:0]    fp;                          // current frame
  pyval_t             globals [N_GLOBALS];
  logic               aw_done, w_done;
  // Interrupt state
  logic               ie, in_irq, vec_set;
  logic [CODE_AW-1:0] irq_vec;
  logic [SP_W-1:0]    saved_sp;
  logic [FP_W-1:0]    irq_fp;                      // the handler's frame
  // Multiplier / divider state
  logic               mul_2nd;                     // S_MUL: second clock (product registered)
  logic signed [2*VW-1:0] prod;
  logic [VW-2:0]      dv_rem, dv_n, dv_d;          // 33-bit magnitudes: remainder, dividend bits, divisor
  logic [VW-3:0]      dv_q;                        // quotient bits found so far (32 before the last step)
  logic [4:0]         dv_cnt;                      // S_DIV iterations left - 1

  // Stack indices (sp counts entries; the array index is SI_W bits, valid where used)
  wire [SP_W-1:0] sp_m2 = sp - SP_W'(2);
  wire [SI_W-1:0] si_0 = sp[SI_W-1:0], si_1 = SI_W'(sp - SP_W'(1)), si_2 = sp_m2[SI_W-1:0];
  wire            st_full = (sp == SP_W'(STACK_DEPTH));
  wire [GI_W-1:0] gidx = arg[GI_W-1:0];
  wire            l_bad = int'(arg[7:0]) >= N_LOCALS;  // local / global operand out of range
  wire            g_bad = int'(arg[7:0]) >= N_GLOBALS;
  wire pyval_t tos  = (sp >= 1) ? stk[si_1] : '0;
  wire pyval_t tos1 = (sp >= 2) ? stk[si_2] : '0;
  wire signed [VW-1:0] a = small_val(tos1), b = small_val(tos);
  wire [FP_W+LB_W-1:0] lidx = {fp, arg[LB_W-1:0]};
  wire frame_full = (fp == FP_W'(N_FRAMES - 1));

  // ---------------- integer ALU (fast path) ----------------
  wire  [5:0]          shamt = (b > 33) ? 6'd33 : b[5:0];
  logic signed [VW-1:0] alu_r;
  logic                alu_cmp;           // 1: result is a bool
  always_comb begin
    alu_r = '0;
    alu_cmp = 1'b0;
    case (op)
      OP_BINARY_ADD:    alu_r = a + b;
      OP_BINARY_SUB:    alu_r = a - b;
      OP_BINARY_AND:    alu_r = a & b;
      OP_BINARY_OR:     alu_r = a | b;
      OP_BINARY_XOR:    alu_r = a ^ b;
      OP_BINARY_LSHIFT: alu_r = a <<< shamt;
      OP_BINARY_RSHIFT: alu_r = a >>> shamt;
      OP_COMPARE_LT:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a <  b;
      end
      OP_COMPARE_EQ:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a == b;
      end
      OP_COMPARE_NE:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a != b;
      end
      OP_COMPARE_GT:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a >  b;
      end
      OP_COMPARE_LE:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a <= b;
      end
      OP_COMPARE_GE:    begin
        alu_cmp = 1'b1;
        alu_r[0] = a >= b;
      end
      default: ;
    endcase
  end
  // LSHIFT overflows when bits shifted out (or into the sign) are lost
  wire lshift_ovf = (op == OP_BINARY_LSHIFT) && ((b > 32) || ((alu_r >>> shamt) != a) || !fits_small(alu_r));
  wire shift_neg  = (op == OP_BINARY_LSHIFT || op == OP_BINARY_RSHIFT) && b < 0;   // ValueError in Python
  wire alu_ovf    = !alu_cmp && (!fits_small(alu_r) || lshift_ovf);

  // Truthiness: small ints, True/False/None in hardware; heap objects trap
  wire tos_known  = is_small(tos) || tos == PY_TRUE || tos == PY_FALSE || tos == PY_NONE;
  wire tos_truthy = is_small(tos) ? (tos[VW-1:1] != '0) : (tos == PY_TRUE);

  // Binary ops occupy 0x10-0x1F; MUL, FLOORDIV and MOD take the multi-cycle units
  wire is_binop = (op[7:4] == 4'h1);
  wire is_muldiv = (op == OP_BINARY_MUL) || (op == OP_BINARY_FLOORDIV) || (op == OP_BINARY_MOD);

  // ---------------- multiplier / divider ----------------
  // Magnitudes of the operands (33 bits: |-2**32| = 2**32)
  wire [VW-2:0] ua = a[VW-1] ? ~a[VW-2:0] + (VW-1)'(1) : a[VW-2:0];
  wire [VW-2:0] ub = b[VW-1] ? ~b[VW-2:0] + (VW-1)'(1) : b[VW-2:0];
  // One restoring step: shift the next dividend bit into the remainder, subtract the divisor if it fits.
  // Result: [VW-1] the quotient bit, [VW-2:0] the new remainder (always < d, so 33 bits suffice).
  function automatic logic [VW-1:0] div_step(input logic [VW-2:0] rem, input logic bit_i, input logic [VW-2:0] d);
    logic [VW-1:0] t;
    logic [VW-2:0] diff;
    t = {rem, bit_i};
    diff = t[VW-2:0] - d;                                       // used only when t >= d: t - d < d
    if (t >= {1'b0, d}) div_step = {1'b1, diff[VW-2:0]};
    else                div_step = {1'b0, t[VW-2:0]};
  endfunction
  wire [VW-1:0] st0 = div_step('0, ua[VW-2], ub);              // first iteration (S_EXEC)
  wire [VW-1:0] stn = div_step(dv_rem, dv_n[VW-2], dv_d);      // the S_DIV iteration
  wire [VW-2:0] q_mag = {dv_q, stn[VW-1]};             // after the last iteration
  wire [VW-2:0] r_mag = stn[VW-2:0];
  wire          sa = a[VW-1], sb = b[VW-1];
  wire signed [VW-1:0] q_t = (sa ^ sb) ? -$signed({1'b0, q_mag}) : $signed({1'b0, q_mag});
  wire signed [VW-1:0] r_t = sa ? -$signed({1'b0, r_mag}) : $signed({1'b0, r_mag});
  wire          floor_adj = (r_mag != '0) && (sa != sb);       // Python rounds the quotient down
  wire signed [VW-1:0] q_py = floor_adj ? q_t - 34'sd1 : q_t;
  wire signed [VW-1:0] r_py = floor_adj ? r_t + b : r_t;
  wire signed [VW-1:0] dv_res = (op == OP_BINARY_MOD) ? r_py : q_py;
  wire          prod_ok = (prod[2*VW-1:VW-2] == '0) || (prod[2*VW-1:VW-2] == '1);   // fits a 33-bit small int

  // Bus values: addresses are 0..2**32-1; stored data may be signed or unsigned 32-bit
  wire addr_ok  = is_small(tos1) && a >= 0 && a <= 34'sh0_FFFF_FFFF;
  wire data_ok  = is_small(tos)  && b >= -34'sh0_8000_0000 && b <= 34'sh0_FFFF_FFFF;
  wire raddr_ok = is_small(tos)  && b >= 0 && b <= 34'sh0_FFFF_FFFF;

  wire take_irq = irq_i && ie && vec_set && !in_irq && !frame_full;

  assign code_addr_o  = pc;
  assign const_addr_o = arg[CONST_AW-1:0];
  assign busy_o       = (st != S_IDLE) && (st != S_DONE) && (st != S_TRAP);
  assign in_irq_o     = in_irq;
  assign m_axil.wstrb = 4'hF;

  // Leave the fast path: report the cause and the instruction, stop at it (expanded inside the
  // always_ff below, so every register keeps a single driver)
  `define PY_CORE_TRAP(c) begin \
    trap_cause_o <= (c); \
    trap_pc_o <= ipc; \
    trap_op_o <= op; \
    trap_o <= 1'b1; \
    pc <= ipc; \
    st <= S_TRAP; \
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      pc <= '0;
      ipc <= '0;
      op <= '0;
      arg <= '0;
      nargs <= '0;
      sp <= '0;
      done_o <= 1'b0;
      result_o <= PY_NONE;
      trap_o <= 1'b0;
      trap_cause_o <= TRAP_NONE;
      trap_pc_o <= '0;
      trap_op_o <= '0;
      m_axil.awvalid <= 1'b0;
      m_axil.wvalid <= 1'b0;
      m_axil.bready <= 1'b0;
      m_axil.arvalid <= 1'b0;
      m_axil.rready <= 1'b0;
      m_axil.awaddr <= '0;
      m_axil.wdata <= '0;
      m_axil.araddr <= '0;
      aw_done <= 1'b0;
      w_done <= 1'b0;
      ie <= 1'b0;
      in_irq <= 1'b0;
      vec_set <= 1'b0;
      irq_vec <= '0;
      saved_sp <= '0;
      irq_fp <= '0;
      fp <= '0;
      mul_2nd <= 1'b0;
      prod <= '0;
      dv_rem <= '0;
      dv_q <= '0;
      dv_n <= '0;
      dv_d <= '0;
      dv_cnt <= '0;
      for (int i = 0; i < N_GLOBALS; i++) globals[i] <= PY_NONE;
    end else begin
      case (st)
        // start_i also abandons a pending trap
        S_IDLE, S_DONE, S_TRAP: if (start_i) begin
          pc <= '0;
          sp <= '0;
          done_o <= 1'b0;
          trap_o <= 1'b0;
          trap_cause_o <= TRAP_NONE;
          st <= S_FETCH;
          ie <= 1'b0;
          in_irq <= 1'b0;
          vec_set <= 1'b0;
          fp <= '0;
          for (int i = 0; i < N_GLOBALS; i++) globals[i] <= PY_NONE;
        end else if (st == S_TRAP && resume_i) begin
          trap_o <= 1'b0;
          trap_cause_o <= TRAP_NONE;
          pc <= resume_pc_i;
          st <= S_FETCH;
        end
        // code_addr_o = pc is presented here; data arrives next clock.
        // An interrupt redirects pc and fetches again from the vector.
        // S_WAIT (WAIT_IRQ) holds until irq_i is high, then is this fetch cycle.
        S_FETCH, S_WAIT: if (st == S_FETCH || irq_i) begin
          if (take_irq) begin
            rstk[fp] <= pc;
            saved_sp <= sp;
            in_irq <= 1'b1;
            irq_fp <= fp + 1'b1;
            fp <= fp + 1'b1;
            pc <= irq_vec;
            st <= S_FETCH;                             // also out of S_WAIT: fetch the vector next
          end else begin
            ipc <= pc;
            pc <= pc + 1'b1;
            arg <= '0;
            st <= S_OP;
          end
        end
        S_OP: begin
          op <= code_data_i;
          nargs <= op_args(code_data_i);
          if (op_args(code_data_i) != 0) begin
            pc <= pc + 1'b1;
            st <= S_ARG0;
          end
          else st <= S_EXEC;
        end
        S_ARG0: begin
          arg[7:0] <= code_data_i;
          if (nargs == 2) begin
            pc <= pc + 1'b1;
            st <= S_ARG1;
          end
          else st <= S_EXEC;
        end
        S_ARG1: begin
          arg[15:8] <= code_data_i;
          st <= S_EXEC;
        end

        S_EXEC: begin
          st <= S_FETCH;                                   // default: next instruction
          if (is_binop) begin
            if (sp < 2)                                 `PY_CORE_TRAP(TRAP_STACK)
            else if (!is_small(tos) || !is_small(tos1)) `PY_CORE_TRAP(TRAP_TYPE)
            else if (op == OP_BINARY_MUL) begin
              mul_2nd <= 1'b0;
              st <= S_MUL;
            end else if (is_muldiv) begin               // FLOORDIV / MOD
              if (b == '0) `PY_CORE_TRAP(TRAP_DIV0)
              else begin
                dv_rem <= st0[VW-2:0];
                dv_q <= {{(VW-3){1'b0}}, st0[VW-1]};
                dv_n <= {ua[VW-3:0], 1'b0};
                dv_d <= ub;
                dv_cnt <= 5'd31;
                st <= S_DIV;
              end
            end
            else if (shift_neg || alu_ovf)              `PY_CORE_TRAP(TRAP_OVERFLOW)
            else begin
              stk[si_2] <= alu_cmp ? mk_bool(alu_r[0]) : mk_small(alu_r[VW-2:0]);
              sp <= sp - 1'b1;
            end
          end else case (op)
            OP_NOP: ;
            OP_LOAD_SMALL, OP_LOAD_NONE, OP_LOAD_TRUE, OP_LOAD_FALSE, OP_LOAD_FAST, OP_LOAD_GLOBAL, OP_DUP_TOP: begin
              if (st_full) `PY_CORE_TRAP(TRAP_STACK)
              else if (op == OP_LOAD_FAST && l_bad) `PY_CORE_TRAP(TRAP_INDEX)
              else if (op == OP_LOAD_GLOBAL && g_bad) `PY_CORE_TRAP(TRAP_INDEX)
              else if (op == OP_DUP_TOP && sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else begin
                case (op)
                  OP_LOAD_SMALL:  stk[si_0] <= mk_small(33'($signed(arg[7:0])));
                  OP_LOAD_NONE:   stk[si_0] <= PY_NONE;
                  OP_LOAD_TRUE:   stk[si_0] <= PY_TRUE;
                  OP_LOAD_FALSE:  stk[si_0] <= PY_FALSE;
                  OP_LOAD_FAST:   stk[si_0] <= locals[lidx];
                  OP_LOAD_GLOBAL: stk[si_0] <= globals[gidx];
                  default:        stk[si_0] <= tos;
                endcase
                sp <= sp + 1'b1;
              end
            end
            OP_LOAD_CONST: begin
              if (st_full) `PY_CORE_TRAP(TRAP_STACK)
              else if (int'(arg[7:0]) >= 2**CONST_AW) `PY_CORE_TRAP(TRAP_INDEX)
              else st <= S_CONST;                          // wait one clock for const_data_i
            end
            OP_STORE_FAST, OP_STORE_GLOBAL: begin
              if (sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else if (op == OP_STORE_FAST && l_bad) `PY_CORE_TRAP(TRAP_INDEX)
              else if (op == OP_STORE_GLOBAL && g_bad) `PY_CORE_TRAP(TRAP_INDEX)
              else begin
                if (op == OP_STORE_FAST) locals[lidx] <= tos;
                else globals[gidx] <= tos;
                sp <= sp - 1'b1;
              end
            end
            OP_POP_TOP:
              if (sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else sp <= sp - 1'b1;
            OP_JUMP: pc <= arg[CODE_AW-1:0];
            OP_POP_JUMP_IF_FALSE, OP_POP_JUMP_IF_TRUE: begin
              if (sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else if (!tos_known) `PY_CORE_TRAP(TRAP_TYPE)          // __bool__/__len__ need the runtime
              else begin
                sp <= sp - 1'b1;
                if (tos_truthy == (op == OP_POP_JUMP_IF_TRUE)) pc <= arg[CODE_AW-1:0];
              end
            end
            // mem32[addr] = value
            OP_MEM32_STORE: begin
              if (sp < 2) `PY_CORE_TRAP(TRAP_STACK)
              else if (!is_small(tos) || !is_small(tos1)) `PY_CORE_TRAP(TRAP_TYPE)
              else if (!addr_ok || !data_ok) `PY_CORE_TRAP(TRAP_OVERFLOW)
              else begin
                m_axil.awaddr <= a[31:0];
                m_axil.wdata <= b[31:0];
                m_axil.awvalid <= 1'b1;
                m_axil.wvalid <= 1'b1;
                aw_done <= 1'b0;
                w_done <= 1'b0;
                st <= S_WR;
              end
            end
            OP_MEM32_LOAD: begin
              if (sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else if (!is_small(tos)) `PY_CORE_TRAP(TRAP_TYPE)
              else if (!raddr_ok) `PY_CORE_TRAP(TRAP_OVERFLOW)
              else begin
                m_axil.araddr <= b[31:0];
                m_axil.arvalid <= 1'b1;
                st <= S_RD;
              end
            end
            OP_SET_IRQ_VECTOR: begin
              irq_vec <= arg[CODE_AW-1:0];
              vec_set <= 1'b1;
            end
            OP_IRQ_ENABLE:     ie <= 1'b1;
            OP_IRQ_DISABLE:    ie <= 1'b0;
            OP_RETURN_FROM_IRQ: begin
              if (!in_irq || fp != irq_fp) `PY_CORE_TRAP(TRAP_IRQ_STATE)
              else if (sp < saved_sp) `PY_CORE_TRAP(TRAP_STACK)
              else begin
                pc <= rstk[fp-1'b1];
                fp <= fp - 1'b1;
                sp <= saved_sp;
                in_irq <= 1'b0;
              end
            end
            OP_CALL: begin
              if (frame_full) `PY_CORE_TRAP(TRAP_STACK)
              else begin
                rstk[fp] <= pc;
                fp <= fp + 1'b1;
                pc <= arg[CODE_AW-1:0];
              end
            end
            OP_RETURN: begin
              if (fp == 0 || (in_irq && fp == irq_fp)) `PY_CORE_TRAP(TRAP_FRAME)
              else begin
                pc <= rstk[fp-1'b1];
                fp <= fp - 1'b1;
              end
            end
            OP_WAIT_IRQ: st <= S_WAIT;
            OP_RETURN_VALUE: begin
              if (sp == 0) `PY_CORE_TRAP(TRAP_STACK)
              else begin
                result_o <= tos;
                sp <= sp - 1'b1;
                done_o <= 1'b1;
                st <= S_DONE;
              end
            end
            default: `PY_CORE_TRAP(TRAP_ILLEGAL)
          endcase
        end

        S_CONST: begin
          stk[si_0] <= const_data_i;
          sp <= sp + 1'b1;
          st <= S_FETCH;
        end

        // BINARY_MUL: clock 1 registers the product, clock 2 checks and writes it
        S_MUL: begin
          if (!mul_2nd) begin
            prod <= a * b;
            mul_2nd <= 1'b1;
          end else if (!prod_ok) `PY_CORE_TRAP(TRAP_OVERFLOW)
          else begin
            stk[si_2] <= mk_small(prod[VW-2:0]);
            sp <= sp - 1'b1;
            st <= S_FETCH;
          end
        end

        // FLOORDIV / MOD: one quotient bit per clock (bits 31..0; bit 32 was done in S_EXEC)
        S_DIV: begin
          dv_rem <= stn[VW-2:0];
          dv_q <= q_mag[VW-3:0];
          dv_n <= {dv_n[VW-3:0], 1'b0};
          if (dv_cnt != '0) dv_cnt <= dv_cnt - 1'b1;
          else if (!fits_small(dv_res)) `PY_CORE_TRAP(TRAP_OVERFLOW)     // -2**32 // -1
          else begin
            stk[si_2] <= mk_small(dv_res[VW-2:0]);
            sp <= sp - 1'b1;
            st <= S_FETCH;
          end
        end

        S_WR: begin
          if (m_axil.awvalid && m_axil.awready) begin
            m_axil.awvalid <= 1'b0;
            aw_done <= 1'b1;
          end
          if (m_axil.wvalid  && m_axil.wready)  begin
            m_axil.wvalid  <= 1'b0;
            w_done  <= 1'b1;
          end
          if ((aw_done || (m_axil.awvalid && m_axil.awready)) && (w_done || (m_axil.wvalid && m_axil.wready)))
            m_axil.bready <= 1'b1;
          if (m_axil.bready && m_axil.bvalid) begin
            m_axil.bready <= 1'b0;
            if (m_axil.bresp != 2'b00) `PY_CORE_TRAP(TRAP_BUS)
            else begin
              sp <= sp_m2;
              st <= S_FETCH;
            end
          end
        end

        // Read data is unsigned: any 32-bit register value is a small int
        S_RD: begin
          if (m_axil.arvalid && m_axil.arready) begin
            m_axil.arvalid <= 1'b0;
            m_axil.rready <= 1'b1;
          end
          if (m_axil.rready && m_axil.rvalid) begin
            m_axil.rready <= 1'b0;
            if (m_axil.rresp != 2'b00) `PY_CORE_TRAP(TRAP_BUS)
            else begin
              stk[si_1] <= mk_small({1'b0, m_axil.rdata});
              st <= S_FETCH;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
`undef PY_CORE_TRAP
