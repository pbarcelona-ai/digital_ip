// ***************
// Filename: py_core.sv
// Author: FPGA Cores 4 U
// Description: Python-bytecode stack machine (sketch). Executes the opcode
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
//   Code memory - byte-wide, synchronous read, 1 clock latency. Constant
//   pool - VW-bit words, same timing. Operand stack, locals, globals -
//   flops; locals - one memory with combinational read (LUT RAM).
//   Clock - clk only. Reset - synchronous rst_n (active low).
//   Throughput - multi-cycle FSM, 2 + operand-byte clocks per instruction,
//   plus bus latency for mem32. Status - architecture sketch.
// Date: 2026-10-01
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
  output logic [31:0]         m_axil_awaddr,
  output logic                m_axil_awvalid,
  input  logic                m_axil_awready,
  output logic [31:0]         m_axil_wdata,
  output logic [3:0]          m_axil_wstrb,
  output logic                m_axil_wvalid,
  input  logic                m_axil_wready,
  input  logic [1:0]          m_axil_bresp,
  input  logic                m_axil_bvalid,
  output logic                m_axil_bready,
  output logic [31:0]         m_axil_araddr,
  output logic                m_axil_arvalid,
  input  logic                m_axil_arready,
  input  logic [31:0]         m_axil_rdata,
  input  logic [1:0]          m_axil_rresp,
  input  logic                m_axil_rvalid,
  output logic                m_axil_rready
);
  import py_core_pkg::*;
  localparam int SP_W = $clog2(STACK_DEPTH + 1);
  localparam int LB_W = $clog2(N_LOCALS);
  localparam int FP_W = $clog2(N_FRAMES);

  typedef enum logic [3:0] {S_IDLE, S_FETCH, S_OP, S_ARG0, S_ARG1, S_EXEC, S_CONST, S_WR, S_RD, S_DONE, S_TRAP} state_e;
  state_e st;

  logic [CODE_AW-1:0] pc, ipc;          // ipc: address of the current instruction
  logic [7:0]         op;
  logic [15:0]        arg;
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

  wire pyval_t tos  = (sp >= 1) ? stk[sp-1] : '0;
  wire pyval_t tos1 = (sp >= 2) ? stk[sp-2] : '0;
  wire signed [VW-1:0] a = small_val(tos1), b = small_val(tos);
  wire [FP_W+LB_W-1:0] lidx = {fp, arg[LB_W-1:0]};
  wire frame_full = (fp == FP_W'(N_FRAMES - 1));

  // ---------------- integer ALU (fast path) ----------------
  wire  [5:0]          shamt = (b > 33) ? 6'd33 : b[5:0];
  logic signed [VW-1:0] alu_r;
  logic                alu_cmp;           // 1: result is a bool
  always_comb begin
    alu_r = '0; alu_cmp = 1'b0;
    case (op)
      OP_BINARY_ADD:    alu_r = a + b;
      OP_BINARY_SUB:    alu_r = a - b;
      OP_BINARY_AND:    alu_r = a & b;
      OP_BINARY_OR:     alu_r = a | b;
      OP_BINARY_XOR:    alu_r = a ^ b;
      OP_BINARY_LSHIFT: alu_r = a <<< shamt;
      OP_BINARY_RSHIFT: alu_r = a >>> shamt;
      OP_COMPARE_LT:    begin alu_cmp = 1'b1; alu_r[0] = a <  b; end
      OP_COMPARE_EQ:    begin alu_cmp = 1'b1; alu_r[0] = a == b; end
      OP_COMPARE_NE:    begin alu_cmp = 1'b1; alu_r[0] = a != b; end
      OP_COMPARE_GT:    begin alu_cmp = 1'b1; alu_r[0] = a >  b; end
      OP_COMPARE_LE:    begin alu_cmp = 1'b1; alu_r[0] = a <= b; end
      OP_COMPARE_GE:    begin alu_cmp = 1'b1; alu_r[0] = a >= b; end
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

  // Binary ops occupy 0x10-0x1D (0x17 is unassigned)
  wire is_binop = (op[7:4] == 4'h1) && (op[3:0] <= 4'hD) && (op[3:0] != 4'h7);

  // Bus values: addresses are 0..2**32-1; stored data may be signed or unsigned 32-bit
  wire addr_ok  = is_small(tos1) && a >= 0 && a <= 34'sh0_FFFF_FFFF;
  wire data_ok  = is_small(tos)  && b >= -34'sh0_8000_0000 && b <= 34'sh0_FFFF_FFFF;
  wire raddr_ok = is_small(tos)  && b >= 0 && b <= 34'sh0_FFFF_FFFF;

  wire take_irq = irq_i && ie && vec_set && !in_irq && !frame_full;

  assign code_addr_o  = pc;
  assign const_addr_o = arg[CONST_AW-1:0];
  assign busy_o       = (st != S_IDLE) && (st != S_DONE) && (st != S_TRAP);
  assign in_irq_o     = in_irq;
  assign m_axil_wstrb = 4'hF;

  task automatic trap(input trap_e c);
    trap_cause_o <= c; trap_pc_o <= ipc; trap_op_o <= op; trap_o <= 1'b1; pc <= ipc; st <= S_TRAP;
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; pc <= '0; ipc <= '0; op <= '0; arg <= '0; nargs <= '0; sp <= '0;
      done_o <= 1'b0; result_o <= PY_NONE; trap_o <= 1'b0; trap_cause_o <= TRAP_NONE; trap_pc_o <= '0; trap_op_o <= '0;
      m_axil_awvalid <= 1'b0; m_axil_wvalid <= 1'b0; m_axil_bready <= 1'b0; m_axil_arvalid <= 1'b0; m_axil_rready <= 1'b0;
      m_axil_awaddr <= '0; m_axil_wdata <= '0; m_axil_araddr <= '0; aw_done <= 1'b0; w_done <= 1'b0;
      ie <= 1'b0; in_irq <= 1'b0; vec_set <= 1'b0; irq_vec <= '0; saved_sp <= '0; irq_fp <= '0; fp <= '0;
      for (int i = 0; i < N_GLOBALS; i++) globals[i] <= PY_NONE;
    end else begin
      case (st)
        // start_i also abandons a pending trap
        S_IDLE, S_DONE, S_TRAP: if (start_i) begin
          pc <= '0; sp <= '0; done_o <= 1'b0; trap_o <= 1'b0; trap_cause_o <= TRAP_NONE; st <= S_FETCH;
          ie <= 1'b0; in_irq <= 1'b0; vec_set <= 1'b0; fp <= '0;
          for (int i = 0; i < N_GLOBALS; i++) globals[i] <= PY_NONE;
        end else if (st == S_TRAP && resume_i) begin
          trap_o <= 1'b0; trap_cause_o <= TRAP_NONE; pc <= resume_pc_i; st <= S_FETCH;
        end
        // code_addr_o = pc is presented here; data arrives next clock.
        // An interrupt redirects pc and fetches again from the vector.
        S_FETCH: begin
          if (take_irq) begin
            rstk[fp] <= pc; saved_sp <= sp; in_irq <= 1'b1; irq_fp <= fp + 1'b1; fp <= fp + 1'b1; pc <= irq_vec;
          end else begin
            ipc <= pc; pc <= pc + 1'b1; arg <= '0; st <= S_OP;
          end
        end
        S_OP: begin
          op <= code_data_i; nargs <= op_args(code_data_i);
          if (op_args(code_data_i) != 0) begin pc <= pc + 1'b1; st <= S_ARG0; end
          else st <= S_EXEC;
        end
        S_ARG0: begin
          arg[7:0] <= code_data_i;
          if (nargs == 2) begin pc <= pc + 1'b1; st <= S_ARG1; end
          else st <= S_EXEC;
        end
        S_ARG1: begin arg[15:8] <= code_data_i; st <= S_EXEC; end

        S_EXEC: begin
          st <= S_FETCH;                                   // default: next instruction
          if (is_binop) begin
            if (sp < 2)                                 trap(TRAP_STACK);
            else if (!is_small(tos) || !is_small(tos1)) trap(TRAP_TYPE);
            else if (shift_neg || alu_ovf)              trap(TRAP_OVERFLOW);
            else begin
              stk[sp-2] <= alu_cmp ? mk_bool(alu_r[0]) : mk_small(alu_r[VW-2:0]);
              sp <= sp - 1'b1;
            end
          end else case (op)
            OP_NOP: ;
            OP_LOAD_SMALL, OP_LOAD_NONE, OP_LOAD_TRUE, OP_LOAD_FALSE, OP_LOAD_FAST, OP_LOAD_GLOBAL, OP_DUP_TOP: begin
              if (sp == STACK_DEPTH) trap(TRAP_STACK);
              else if (op == OP_LOAD_FAST && arg[7:0] >= N_LOCALS) trap(TRAP_INDEX);
              else if (op == OP_LOAD_GLOBAL && arg[7:0] >= N_GLOBALS) trap(TRAP_INDEX);
              else if (op == OP_DUP_TOP && sp == 0) trap(TRAP_STACK);
              else begin
                case (op)
                  OP_LOAD_SMALL:  stk[sp] <= mk_small(33'($signed(arg[7:0])));
                  OP_LOAD_NONE:   stk[sp] <= PY_NONE;
                  OP_LOAD_TRUE:   stk[sp] <= PY_TRUE;
                  OP_LOAD_FALSE:  stk[sp] <= PY_FALSE;
                  OP_LOAD_FAST:   stk[sp] <= locals[lidx];
                  OP_LOAD_GLOBAL: stk[sp] <= globals[arg[7:0]];
                  default:        stk[sp] <= tos;
                endcase
                sp <= sp + 1'b1;
              end
            end
            OP_LOAD_CONST: begin
              if (sp == STACK_DEPTH) trap(TRAP_STACK);
              else if (arg[7:0] >= 2**CONST_AW) trap(TRAP_INDEX);
              else st <= S_CONST;                          // wait one clock for const_data_i
            end
            OP_STORE_FAST, OP_STORE_GLOBAL: begin
              if (sp == 0) trap(TRAP_STACK);
              else if (op == OP_STORE_FAST && arg[7:0] >= N_LOCALS) trap(TRAP_INDEX);
              else if (op == OP_STORE_GLOBAL && arg[7:0] >= N_GLOBALS) trap(TRAP_INDEX);
              else begin
                if (op == OP_STORE_FAST) locals[lidx] <= tos; else globals[arg[7:0]] <= tos;
                sp <= sp - 1'b1;
              end
            end
            OP_POP_TOP: if (sp == 0) trap(TRAP_STACK); else sp <= sp - 1'b1;
            OP_JUMP: pc <= arg[CODE_AW-1:0];
            OP_POP_JUMP_IF_FALSE, OP_POP_JUMP_IF_TRUE: begin
              if (sp == 0) trap(TRAP_STACK);
              else if (!tos_known) trap(TRAP_TYPE);          // __bool__/__len__ need the runtime
              else begin
                sp <= sp - 1'b1;
                if (tos_truthy == (op == OP_POP_JUMP_IF_TRUE)) pc <= arg[CODE_AW-1:0];
              end
            end
            // mem32[addr] = value
            OP_MEM32_STORE: begin
              if (sp < 2) trap(TRAP_STACK);
              else if (!is_small(tos) || !is_small(tos1)) trap(TRAP_TYPE);
              else if (!addr_ok || !data_ok) trap(TRAP_OVERFLOW);
              else begin
                m_axil_awaddr <= a[31:0]; m_axil_wdata <= b[31:0];
                m_axil_awvalid <= 1'b1; m_axil_wvalid <= 1'b1; aw_done <= 1'b0; w_done <= 1'b0;
                st <= S_WR;
              end
            end
            OP_MEM32_LOAD: begin
              if (sp == 0) trap(TRAP_STACK);
              else if (!is_small(tos)) trap(TRAP_TYPE);
              else if (!raddr_ok) trap(TRAP_OVERFLOW);
              else begin m_axil_araddr <= b[31:0]; m_axil_arvalid <= 1'b1; st <= S_RD; end
            end
            OP_SET_IRQ_VECTOR: begin irq_vec <= arg[CODE_AW-1:0]; vec_set <= 1'b1; end
            OP_IRQ_ENABLE:     ie <= 1'b1;
            OP_IRQ_DISABLE:    ie <= 1'b0;
            OP_RETURN_FROM_IRQ: begin
              if (!in_irq || fp != irq_fp) trap(TRAP_IRQ_STATE);
              else begin pc <= rstk[fp-1'b1]; fp <= fp - 1'b1; sp <= saved_sp; in_irq <= 1'b0; end
            end
            OP_CALL: begin
              if (frame_full) trap(TRAP_STACK);
              else begin rstk[fp] <= pc; fp <= fp + 1'b1; pc <= arg[CODE_AW-1:0]; end
            end
            OP_RETURN: begin
              if (fp == 0 || (in_irq && fp == irq_fp)) trap(TRAP_FRAME);
              else begin pc <= rstk[fp-1'b1]; fp <= fp - 1'b1; end
            end
            OP_RETURN_VALUE: begin
              if (sp == 0) trap(TRAP_STACK);
              else begin result_o <= tos; sp <= sp - 1'b1; done_o <= 1'b1; st <= S_DONE; end
            end
            default: trap(TRAP_ILLEGAL);
          endcase
        end

        S_CONST: begin stk[sp] <= const_data_i; sp <= sp + 1'b1; st <= S_FETCH; end

        S_WR: begin
          if (m_axil_awvalid && m_axil_awready) begin m_axil_awvalid <= 1'b0; aw_done <= 1'b1; end
          if (m_axil_wvalid  && m_axil_wready)  begin m_axil_wvalid  <= 1'b0; w_done  <= 1'b1; end
          if ((aw_done || (m_axil_awvalid && m_axil_awready)) && (w_done || (m_axil_wvalid && m_axil_wready)))
            m_axil_bready <= 1'b1;
          if (m_axil_bready && m_axil_bvalid) begin
            m_axil_bready <= 1'b0;
            if (m_axil_bresp != 2'b00) trap(TRAP_BUS);
            else begin sp <= sp - 2'd2; st <= S_FETCH; end
          end
        end

        // Read data is unsigned: any 32-bit register value is a small int
        S_RD: begin
          if (m_axil_arvalid && m_axil_arready) begin m_axil_arvalid <= 1'b0; m_axil_rready <= 1'b1; end
          if (m_axil_rready && m_axil_rvalid) begin
            m_axil_rready <= 1'b0;
            if (m_axil_rresp != 2'b00) trap(TRAP_BUS);
            else begin stk[sp-1] <= mk_small({1'b0, m_axil_rdata}); st <= S_FETCH; end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
