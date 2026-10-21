<!-- Industry reference check of py_core: copied into docs/py_core_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - py_core (2026-10-16, updated 2026-10-20)
// Sources:
//   [1] Python Software Foundation, "dis - Disassembler for Python bytecode",
//   https://docs.python.org/3/library/dis.html (CPython stack machine; bytecode is a CPython
//   detail that changes between versions)
// Published algorithm / equations:
//   CPython executes bytecode on a stack machine (LOAD_FAST / STORE_FAST locals, LOAD_CONST,
//   BINARY_OP, COMPARE_OP, jumps, CALL / RETURN_VALUE); the bytecode format is a CPython
//   implementation detail that changes between Python versions.
// Comparison with this IP (section 6):
//   Matches the execution model: operand stack, per-frame locals, globals, constant pool, call
//   / return with a return stack, traps for what the fast path cannot do (heap objects,
//   bigints, RecursionError on too deep calls). Differs: the opcode set is the library's own
//   (py_core_pkg), not CPython bytecode of a given Python version, and ints are 33-bit (CPython
//   ints are unbounded; overflow must trap).
// RESOLVED(REF-PY_CORE-1) [LOW] Opcode set is not CPython bytecode. Resolution: 2026-10-20: the
//   py_core_pkg.sv header maps every py_core opcode to its CPython 3.12 dis counterpart (name,
//   stack effect, argument) and states that pyc.py compiles the Python source's AST directly
//   (not CPython bytecode); tb/python runs pyc.py-compiled programs (programs/prog_v1.py,
//   prog_v2.py) on the RTL against the golden model.
// RESOLVED(REF-PY_CORE-2) [LOW] Small-int overflow. Resolution: 2026-10-20: every arithmetic
//   opcode whose exact result does not fit 33 bits raises TRAP_OVERFLOW (ADD / SUB / LSHIFT by
//   fits_small and the shift-back check, MUL by the 66-bit product's top bits, FLOORDIV for
//   -2**32 // -1; no wrap-around); tests: py_core_tb tests 3 (ADD) and 12 (MUL), and the cocotb
//   random programs (every opcode with the 32-bit corner operands, OVERFLOW ends counted).
```
