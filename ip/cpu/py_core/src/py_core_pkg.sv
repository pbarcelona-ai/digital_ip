// ***************
// Filename: py_core_pkg.sv
// Author: FPGA Cores 4 U
// Description: Shared definitions for py_core, a stack machine that executes
//   a Python-bytecode-style instruction set directly. Defines the tagged
//   value format, the opcode map, and the trap causes reported when an
//   instruction leaves the hardware fast path.
//
//   Value format (VW = 34-bit word, MicroPython-style tagging):
//     [33:1] value, [0]=1  small int, 33-bit signed: every 32-bit register
//                          value, signed or unsigned, is a small int
//     [1:0] = 2'b10        immediate object, index = word >> 2:
//                            0 = None, 1 = False, 2 = True
//     [1:0] = 2'b00        heap object pointer (never handled in hardware)
//
//   Encoding: 1 opcode byte, then 0, 1 or 2 little-endian operand bytes.
//   The opcode set is MicroPython-inspired but NOT the real .mpy encoding;
//   tools/pyc.py compiles a Python subset into it.
// Date: 2026-10-01
package py_core_pkg;

  localparam int VW = 34;                 // tagged value width
  typedef logic [VW-1:0] pyval_t;

  // ---------------- tagged values ----------------
  localparam pyval_t PY_NONE  = 34'h0_0000_0002;
  localparam pyval_t PY_FALSE = 34'h0_0000_0006;
  localparam pyval_t PY_TRUE  = 34'h0_0000_000A;

  function automatic logic is_small(input pyval_t v);
    is_small = v[0];
  endfunction
  function automatic pyval_t mk_small(input logic signed [VW-2:0] i);
    mk_small = {i, 1'b1};
  endfunction
  function automatic logic signed [VW-1:0] small_val(input pyval_t v);
    small_val = $signed(v) >>> 1;
  endfunction
  // A VW-bit integer fits in a small int when its top two bits agree
  function automatic logic fits_small(input logic signed [VW-1:0] i);
    fits_small = i[VW-1] == i[VW-2];
  endfunction
  function automatic pyval_t mk_bool(input logic b);
    mk_bool = b ? PY_TRUE : PY_FALSE;
  endfunction

  // ---------------- opcodes ----------------
  typedef enum logic [7:0] {
    OP_NOP           = 8'h00,
    OP_LOAD_SMALL    = 8'h01,  // imm8 (signed)  push small int
    OP_LOAD_CONST    = 8'h02,  // idx8           push const_pool[idx]
    OP_LOAD_FAST     = 8'h03,  // n8             push locals[n]
    OP_STORE_FAST    = 8'h04,  // n8             locals[n] = pop
    OP_POP_TOP       = 8'h05,
    OP_DUP_TOP       = 8'h06,
    OP_LOAD_NONE     = 8'h07,
    OP_LOAD_GLOBAL   = 8'h08,  // n8             push globals[n]
    OP_STORE_GLOBAL  = 8'h09,  // n8             globals[n] = pop
    OP_LOAD_TRUE     = 8'h0A,
    OP_LOAD_FALSE    = 8'h0B,
    OP_BINARY_ADD    = 8'h10,  // TOS1 + TOS
    OP_BINARY_SUB    = 8'h11,
    OP_BINARY_AND    = 8'h12,
    OP_BINARY_OR     = 8'h13,
    OP_BINARY_XOR    = 8'h14,
    OP_BINARY_LSHIFT = 8'h15,
    OP_BINARY_RSHIFT = 8'h16,
    OP_COMPARE_LT    = 8'h18,
    OP_COMPARE_EQ    = 8'h19,
    OP_COMPARE_NE    = 8'h1A,
    OP_COMPARE_GT    = 8'h1B,
    OP_COMPARE_LE    = 8'h1C,
    OP_COMPARE_GE    = 8'h1D,
    OP_JUMP          = 8'h20,  // abs16
    OP_POP_JUMP_IF_FALSE = 8'h21, // abs16
    OP_POP_JUMP_IF_TRUE  = 8'h22, // abs16
    OP_MEM32_LOAD    = 8'h30,  // push mem32[pop]           (AXI4-Lite read)
    OP_MEM32_STORE   = 8'h31,  // v = pop; a = pop; mem32[a] = v (AXI4-Lite write)
    OP_SET_IRQ_VECTOR = 8'h38, // abs16          handler entry address
    OP_IRQ_ENABLE    = 8'h39,
    OP_IRQ_DISABLE   = 8'h3A,
    OP_RETURN_FROM_IRQ = 8'h3B,
    OP_CALL          = 8'h3C,  // abs16          push a frame, jump (callee pops its args with STORE_FAST)
    OP_RETURN        = 8'h3D,  // pop the frame; the return value stays on the operand stack
    OP_RETURN_VALUE  = 8'h3F   // halt, result = pop
  } opcode_e;

  // Number of operand bytes after the opcode
  function automatic logic [1:0] op_args(input logic [7:0] op);
    case (op)
      OP_LOAD_SMALL, OP_LOAD_CONST, OP_LOAD_FAST, OP_STORE_FAST,
      OP_LOAD_GLOBAL, OP_STORE_GLOBAL:                                    op_args = 2'd1;
      OP_JUMP, OP_POP_JUMP_IF_FALSE, OP_POP_JUMP_IF_TRUE, OP_SET_IRQ_VECTOR,
      OP_CALL:                                                            op_args = 2'd2;
      default:                                                            op_args = 2'd0;
    endcase
  endfunction

  // ---------------- trap causes ----------------
  typedef enum logic [3:0] {
    TRAP_NONE      = 4'h0,
    TRAP_ILLEGAL   = 4'h1,  // opcode not implemented in hardware (slow path)
    TRAP_TYPE      = 4'h2,  // operand is not a small int / bool (slow path)
    TRAP_OVERFLOW  = 4'h3,  // result needs a bigint (slow path)
    TRAP_STACK     = 4'h4,  // operand stack or call depth overflow/underflow
    TRAP_BUS       = 4'h5,  // SLVERR/DECERR on mem32 access
    TRAP_INDEX     = 4'h6,  // local / global / const index out of range
    TRAP_IRQ_STATE = 4'h7,  // RETURN_FROM_IRQ outside a handler frame
    TRAP_FRAME     = 4'h8   // RETURN with no caller (or from a handler frame)
  } trap_e;

endpackage
